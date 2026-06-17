import Foundation
import CoreLocation
import Combine
import MapKit
import AnumaanCore

/// Drives a clear, stepped flow:  area → home → route → navigating.
@MainActor
final class NavViewModel: ObservableObject {
    enum Phase { case area, home, route, navigating }
    enum SearchContext { case area, start, dest }
    struct Suggestion: Identifiable {
        let id = UUID(); let title: String; let subtitle: String; let raw: MKLocalSearchCompletion
    }

    // flow
    @Published var phase: Phase = .area
    @Published var status = ""
    @Published var busy = false
    @Published var currentAreaName: String?
    @Published var demInfo = ""            // offline-elevation status for the area
    @Published var basemapInfo = ""        // offline-basemap (tile cache) status
    @Published var featInfo = ""           // offline map-features status

    // map
    @Published var center = CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35)
    @Published var recenterTrigger = 0
    @Published var recenterZoom = 4.0
    @Published var follow = false
    @Published var home: CLLocationCoordinate2D?
    @Published var startPin: CLLocationCoordinate2D?
    @Published var destPin: CLLocationCoordinate2D?
    @Published var routeCoords: [CLLocationCoordinate2D] = []
    @Published var vehicle: CLLocationCoordinate2D?
    @Published var nextMilestone: CLLocationCoordinate2D?

    // text entry + autocomplete
    @Published var areaQuery = ""
    @Published var startQuery = ""
    @Published var destQuery = ""
    @Published var suggestions: [Suggestion] = []

    // HUD
    @Published var speed = 0.0
    @Published var moving = "—"
    @Published var headingText = "—"
    @Published var nodeText = "—"
    @Published var limitText = "—"          // posted speed limit for the current leg
    @Published var turnArrow: String?      // SF Symbol arrow pointing the way to turn
    @Published var approachLabel = ""
    @Published var approachDetail = ""      // "~120 m" / calibration hint
    @Published var calibrated = false
    @Published var paceNote = ""            // result of the leg-1 sensor validation
    @Published var autoMode = false         // after a few milestones, advance on its own
    @Published var autoPaused = false       // user pressed "not yet" — hold the dot

    private var confirmedCount = 0          // milestones confirmed (manual or auto)
    private let autoThreshold = 2           // auto-advance kicks in after this many
    private var legStartAlt = 0.0           // barometer baseline for the current leg
    private var legExpectedClimb: [Double] = []   // DEM-expected Δelevation per leg
    private var headingOffset = 0.0         // magnetic→true (WMM declination, +east)

    @Published var cadence = 0.0

    let sensing = SensingService()
    private let gait = GaitModel()
    private let calib = CalibrationAnalyzer()
    private var sensorPredictive = false     // did leg-1 prove the sensors predict speed?
    private let completer = SearchCompleter()
    private var searchCtx: SearchContext = .area
    private var atlas: Atlas?               // merged offline map across all downloaded patches
    @Published var coverageRects: [[CLLocationCoordinate2D]] = []   // downloaded-area outlines for the map
    @Published var plannedRects: [[CLLocationCoordinate2D]] = []    // queued (not-yet-downloaded) chunks
    @Published var planActive = false       // a region plan is staged or running
    @Published var planRunning = false      // the queue is actively downloading
    @Published var planText = ""            // "6 downloads to cover this region" / "Downloading 3 of 6…"
    private var pendingTiles: [(s: Double, w: Double, n: Double, e: Double)] = []
    private var stopPlan = false
    private var route: Route?
    private var routeCum: [Double] = []     // cumulative polyline distance, precomputed
    private var lastNavLog = 0.0
    private var engine: NavigationEngine?
    private var ticker: Timer?
    private var t0 = Date()
    private var visible: (s: Double, w: Double, n: Double, e: Double)?

    init() {
        sensing.start(); loadHome()
        completer.onResults = { [weak self] results in
            self?.suggestions = results.map {
                Suggestion(title: $0.title, subtitle: $0.subtitle, raw: $0)
            }
        }
        loadAtlas()
    }

    /// Build the merged offline map across ALL downloaded patches (off-main).
    private func loadAtlas() {
        Task { [weak self] in
            let a = await Atlas.build()
            guard let self else { return }
            if let a {
                self.atlas = a
                self.applyCoverage()
                let c = a.center
                self.center = c; self.recenterZoom = 12; self.recenterTrigger += 1
                self.headingOffset = GeoMagnetism.declination(latDeg: c.latitude, lonDeg: c.longitude, year: AppTime.decimalYear())
                self.sensing.declinationOffset = self.headingOffset
                self.currentAreaName = a.patches.count == 1 ? a.patches[0].name : "\(a.patches.count) areas"
                self.demInfo = "Offline elevation ready"; self.basemapInfo = "Offline basemap ready"
                self.featInfo = "Offline features ready"
                self.phase = .route; self.status = ""
            } else {
                self.phase = .area
                self.status = "Search a place, frame it, then download it."
            }
        }
    }

    private func applyCoverage() {
        coverageRects = (atlas?.coverage ?? []).map { b in
            [CLLocationCoordinate2D(latitude: b.s, longitude: b.w),
             .init(latitude: b.s, longitude: b.e), .init(latitude: b.n, longitude: b.e),
             .init(latitude: b.n, longitude: b.w), .init(latitude: b.s, longitude: b.w)]
        }
    }

    func regionChanged(s: Double, w: Double, n: Double, e: Double) { visible = (s, w, n, e) }

    // MARK: autocomplete
    func updateSuggestions(_ q: String, _ ctx: SearchContext) {
        searchCtx = ctx
        completer.query(q, placesOnly: ctx == .area)   // area: cities/towns only
    }
    func clearSuggestions() { suggestions = [] }
    func pick(_ s: Suggestion) {
        suggestions = []
        Task {
            guard let c = await SearchCompleter.resolve(s.raw) else { status = "Couldn't locate that."; return }
            switch searchCtx {
            case .area:  areaQuery = s.title; recenter(c, zoom: 13); status = "Framed \(s.title). Download roads."
            case .start: startQuery = s.title; startPin = c; recenter(c, zoom: 15); status = "Start set."
            case .dest:  destQuery = s.title; destPin = c; recenter(c, zoom: 15); status = "Destination set."
            }
        }
    }
    private func recenter(_ c: CLLocationCoordinate2D, zoom: Double) {
        center = c; recenterZoom = zoom; recenterTrigger += 1
    }

    /// Turn the (portrait, tall) visible viewport into a sensible download box:
    /// make it roughly SQUARE in real distance (no more long thin rectangles), and
    /// BRIDGE it to any existing patch it's nearly touching so adjacent downloads
    /// connect instead of leaving a gap. Everything stays under the routing cap.
    private func fitDownloadBox(_ b: (s: Double, w: Double, n: Double, e: Double))
        -> (s: Double, w: Double, n: Double, e: Double) {
        let maxSpan = 0.35, gap = 0.15
        var (s, w, n, e) = b
        let cosLat = max(0.2, cos(((s + n) / 2) * .pi / 180))
        // square up in real distance (lon degrees are shorter than lat degrees)
        let hM = n - s, wM = (e - w) * cosLat
        if hM > wM { let add = (hM - wM) / 2 / cosLat; w -= add; e += add }
        else if wM > hM { let add = (wM - hM) / 2; s -= add; n += add }
        if n - s > maxSpan { let c = (s + n) / 2; s = c - maxSpan / 2; n = c + maxSpan / 2 }
        if e - w > maxSpan { let c = (w + e) / 2; w = c - maxSpan / 2; e = c + maxSpan / 2 }
        // bridge to nearby existing coverage (only if the result still fits the cap)
        for p in AtlasStore.patches() {
            let latOverlap = !(n < p.south || s > p.north)
            let lonOverlap = !(e < p.west || w > p.east)
            if latOverlap {
                if p.west > e, p.west - e <= gap, p.west - w <= maxSpan { e = p.west }
                if p.east < w, w - p.east <= gap, e - p.east <= maxSpan { w = p.east }
            }
            if lonOverlap {
                if p.south > n, p.south - n <= gap, p.south - s <= maxSpan { n = p.south }
                if p.north < s, s - p.north <= gap, n - p.north <= maxSpan { s = p.north }
            }
        }
        return (s, w, n, e)
    }

    // MARK: step 1 — area
    func downloadRoads() {
        let raw = visible ?? (s: center.latitude - 0.02, w: center.longitude - 0.02,
                              n: center.latitude + 0.02, e: center.longitude + 0.02)
        if (raw.n - raw.s) > 0.35 || (raw.e - raw.w) > 0.35 {
            status = "Too big to route on-device — frame a city/metro area (not a whole state)."
            return
        }
        let b = fitDownloadBox(raw)
        let name = areaQuery.isEmpty ? "Area \(AtlasStore.patches().count + 1)" : areaQuery
        status = "Downloading “\(name)” — roads, elevation, features…"
        Task {
            if await fetchPatch(name: name, b: b) {
                self.status = "Added “\(name)” — \(self.coverageRects.count) area(s) now offline."
                self.phase = .home
            }
        }
    }

    /// Download ONE chunk (roads + elevation + features + basemap) and add it to
    /// the atlas. Reused by single downloads and by the scheduled region queue.
    @discardableResult
    private func fetchPatch(name: String, b: (s: Double, w: Double, n: Double, e: Double)) async -> Bool {
        busy = true
        let center = CLLocationCoordinate2D(latitude: (b.s + b.n) / 2, longitude: (b.w + b.e) / 2)
        do {
            let g = try await OverpassService.downloadGraph(south: b.s, west: b.w, north: b.n, east: b.e)
            var dem: TerrariumDEM?
            do { dem = try await DEMService.download(south: b.s, west: b.w, north: b.n, east: b.e,
                                                     centerLat: center.latitude, centerLon: center.longitude)
                 self.demInfo = "Offline elevation ready"
            } catch { self.demInfo = "Elevation skipped: \(error.localizedDescription)" }
            var feats: FeatureField?
            do { feats = try await FeatureService.download(south: b.s, west: b.w, north: b.n, east: b.e,
                                                           centerLat: center.latitude, centerLon: center.longitude)
                 self.featInfo = "Offline features ready"
            } catch { self.featInfo = "Features skipped: \(error.localizedDescription)" }
            AtlasStore.addPatch(name: name, south: b.s, west: b.w, north: b.n, east: b.e,
                                center: center, graph: g, dem: dem, features: feats)
            self.cacheBasemap(south: b.s, west: b.w, north: b.n, east: b.e)
            self.atlas = await Atlas.build()
            self.applyCoverage()
            let cnt = self.atlas?.patches.count ?? 1
            self.currentAreaName = cnt == 1 ? name : "\(cnt) areas"
            let c = self.atlas?.center ?? center
            self.headingOffset = GeoMagnetism.declination(latDeg: c.latitude, lonDeg: c.longitude, year: AppTime.decimalYear())
            self.sensing.declinationOffset = self.headingOffset
            self.busy = false
            return true
        } catch { self.status = "Download failed: \(error.localizedDescription)"; self.busy = false; return false }
    }

    // MARK: large region — plan into grid-aligned chunks, then download on a queue
    private let chunkDeg = 0.30                   // each download ≈ this, under the 0.35° routing cap
    private let planDelaySec: UInt64 = 10         // pause between chunks — easy on the free servers

    /// Tile the framed region onto a FIXED global grid (so chunks always abut with
    /// no gaps), dropping any cell already covered by an existing patch.
    private func tileRegion(_ r: (s: Double, w: Double, n: Double, e: Double))
        -> (todo: [(s: Double, w: Double, n: Double, e: Double)], total: Int) {
        let c = chunkDeg
        let i0 = Int(floor(r.w / c)), i1 = Int(floor((r.e - 1e-9) / c))
        let j0 = Int(floor(r.s / c)), j1 = Int(floor((r.n - 1e-9) / c))
        guard i1 >= i0, j1 >= j0 else { return ([], 0) }
        let patches = AtlasStore.patches()
        var todo: [(s: Double, w: Double, n: Double, e: Double)] = []
        for i in i0...i1 { for j in j0...j1 {
            let cell = (s: Double(j) * c, w: Double(i) * c, n: Double(j + 1) * c, e: Double(i + 1) * c)
            let clat = (cell.s + cell.n) / 2, clon = (cell.w + cell.e) / 2
            let covered = patches.contains { clat >= $0.south && clat <= $0.north && clon >= $0.west && clon <= $0.east }
            if !covered { todo.append(cell) }
        }}
        return (todo, (i1 - i0 + 1) * (j1 - j0 + 1))
    }

    private func rect(_ b: (s: Double, w: Double, n: Double, e: Double)) -> [CLLocationCoordinate2D] {
        [.init(latitude: b.s, longitude: b.w), .init(latitude: b.s, longitude: b.e),
         .init(latitude: b.n, longitude: b.e), .init(latitude: b.n, longitude: b.w), .init(latitude: b.s, longitude: b.w)]
    }

    /// Frame a large region (current map view) → show how many downloads it needs.
    func planArea() {
        let r = visible ?? (s: center.latitude - 0.15, w: center.longitude - 0.15,
                            n: center.latitude + 0.15, e: center.longitude + 0.15)
        let (todo, total) = tileRegion(r)
        pendingTiles = todo
        plannedRects = todo.map { rect($0) }
        planActive = true
        let done = total - todo.count
        planText = todo.isEmpty
            ? "This whole region is already offline ✓"
            : "\(todo.count) download\(todo.count == 1 ? "" : "s") to cover this region" + (done > 0 ? " (\(done) already done)." : ".")
        status = planText
    }

    /// Run the queued chunk downloads sequentially, with a polite delay between
    /// each so we don't hammer the free servers. Stoppable / resumable.
    func downloadPlanned() {
        guard !pendingTiles.isEmpty, !planRunning else { return }
        planRunning = true; stopPlan = false
        Task {
            let tiles = pendingTiles
            for (k, t) in tiles.enumerated() {
                if stopPlan { break }
                planText = "Downloading area \(k + 1) of \(tiles.count)…"
                status = planText
                _ = await fetchPatch(name: "Region \(AtlasStore.patches().count + 1)", b: t)
                pendingTiles = Array(tiles[(k + 1)...])           // shrink the remaining plan
                plannedRects = pendingTiles.map { rect($0) }
                if !stopPlan && k < tiles.count - 1 {
                    try? await Task.sleep(nanoseconds: planDelaySec * 1_000_000_000)
                }
            }
            planRunning = false
            if stopPlan {
                planText = "Paused — \(pendingTiles.count) area(s) left. Tap “Download all” to resume."
            } else {
                planActive = false; plannedRects = []
                planText = ""; status = "Region downloaded — \(coverageRects.count) area(s) offline."
                phase = .home
            }
        }
    }
    func stopPlanned() { stopPlan = true }
    func cancelPlan() { pendingTiles = []; plannedRects = []; planActive = false; planText = ""; status = "" }
    /// Pre-cache basemap vector tiles for the bbox so the map renders offline.
    private func cacheBasemap(south: Double, west: Double, north: Double, east: Double) {
        guard let style = URL(string: "https://tiles.openfreemap.org/styles/liberty") else { return }
        basemapInfo = "Caching offline basemap…"
        OfflineBasemap.shared.onProgress = { [weak self] frac, done in
            self?.basemapInfo = done ? "Offline basemap ready"
                                     : "Caching offline basemap… \(Int(frac * 100))%"
        }
        OfflineBasemap.shared.download(styleURL: style, south: south, west: west, north: north, east: east,
                                       minZoom: 11, maxZoom: 15, name: currentAreaName ?? "area")
    }

    /// "Add area" — frame and download ANOTHER patch; existing offline maps are kept.
    func addArea() {
        phase = .area
        startPin = nil; destPin = nil; startQuery = ""; destQuery = ""; routeCoords = []
        status = "Search a place to ADD to your offline maps."
    }
    /// Wipe ALL downloaded areas.
    func clearAllAreas() {
        AtlasStore.clearAll(); atlas = nil; coverageRects = []; currentAreaName = nil
        demInfo = ""; featInfo = ""; basemapInfo = ""
        phase = .area; status = "Cleared. Search a place to download."
    }

    // MARK: step 2 — home
    func saveHomeAndContinue() { if let h = home { saveHome(h) }; phase = .route; status = "Where to?" }
    func skipHome() { phase = .route; status = "Where to?" }

    // MARK: step 3 — route
    func handleTap(_ c: CLLocationCoordinate2D) {
        switch phase {
        case .home: home = c; status = "Home placed. Save or Skip."
        case .route:
            if startPin == nil { startPin = c; status = "Start set. Now set destination." }
            else { destPin = c; status = "Destination set. Tap Start." }
        default: break
        }
    }
    func useHomeAsStart() {
        guard let h = home else { status = "No home saved."; return }
        startPin = h; startQuery = "Home"; status = "Start = Home. Set a destination."
    }
    func clearStartDest() { startPin = nil; destPin = nil; startQuery = ""; destQuery = ""; routeCoords = [] }
    var canStart: Bool { startPin != nil && destPin != nil && atlas != nil }
    var offlineElevReady: Bool { demInfo.hasPrefix("Offline") }
    var offlineMapReady: Bool { basemapInfo.hasPrefix("Offline") }
    var offlineFeatReady: Bool { featInfo.hasPrefix("Offline") }

    // MARK: step 4 — start (computes route, then navigates)
    func start() {
        guard let atlas, let s = startPin, let d = destPin else { status = "Set start + destination."; return }
        let g = atlas.graph
        guard let a = g.nearestNode(lat: s.latitude, lon: s.longitude),
              let b = g.nearestNode(lat: d.latitude, lon: d.longitude),
              let path = g.shortestPath(from: a, to: b) else { status = "No route found."; return }
        let r = g.buildRoute(path: path)
        route = r
        routeCoords = r.coords.map { .init(latitude: $0[0], longitude: $0[1]) }
        routeCum = [0]                          // precompute once (was recomputed every tick)
        for i in 1..<max(routeCoords.count, 1) {
            routeCum.append(routeCum[i - 1] + Turn.haversine(
                (routeCoords[i - 1].latitude, routeCoords[i - 1].longitude),
                (routeCoords[i].latitude, routeCoords[i].longitude)))
        }
        // Start uncalibrated at a walking guess; the first "I've reached it"
        // sets the real pace from start→milestone distance ÷ time.
        engine = NavigationEngine(route: r.milestones, estimatedSpeed: 1.4, startTime: 0, calibrated: false)
        calibrated = false; sensorPredictive = false; paceNote = ""
        confirmedCount = 0; autoMode = false; autoPaused = false
        legExpectedClimb = expectedClimbPerLeg(r)
        gait.reset(); calib.reset()
        t0 = Date(); follow = true; phase = .navigating
        sensing.resetLeg(); legStartAlt = sensing.altitudeM
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        status = "Start moving. Tap “Reached” at the first stop to calibrate."
        DebugLog.shared.sessionStart("nav", owner: sensing)   // only this sensing logs
        DebugLog.shared.log("nav.start", ["nodes": r.nodes.count, "milestones": r.milestones.count,
                                          "totalM": r.totalDistanceM, "declination": headingOffset])
    }
    func stopNav() {
        ticker?.invalidate(); ticker = nil; follow = false; vehicle = nil; nextMilestone = nil; phase = .route
        approachLabel = ""; approachDetail = ""; turnArrow = nil; paceNote = ""
        status = "Stopped."
    }
    /// "✓ I've reached it" — manual confirm (also used to advance now in auto mode).
    func advance() { doAdvance(now: Date().timeIntervalSince(t0)) }

    /// "✗ Not yet" — the dot ran ahead; pause auto-advance and hold until I confirm.
    func notYet() { autoPaused = true; status = "Holding — tap ✓ when you reach it." }

    /// Confirm arrival at the current milestone and advance the leg.
    private func doAdvance(now: Double) {
        guard let e = engine, !e.isComplete else { return }
        let firstLeg = !e.calibrated
        let legDist = e.nextMilestone.distanceFromPrior
        let legStart = e.timeEnteredLeg
        _ = e.confirmArrival(now: now)
        if firstLeg { validateFirstLeg(distance: legDist) }
        else { refineGait(distance: legDist, seconds: now - legStart) }
        confirmedCount += 1
        autoMode = confirmedCount >= autoThreshold
        autoPaused = false
        DebugLog.shared.log("nav.reached", ["idx": e.currentIndex, "legDist": legDist,
                                            "legSec": now - legStart, "estSpeed": e.estimatedSpeed,
                                            "firstLeg": firstLeg, "auto": autoMode])
        sensing.resetLeg(); legStartAlt = sensing.altitudeM
    }

    /// Bookkeeping after the engine auto-advanced (auto-snap on a genuine stop).
    private func postEngineAdvance(legDist: Double, legStart: Double, now: Double) {
        refineGait(distance: legDist, seconds: now - legStart)
        confirmedCount += 1
        autoMode = confirmedCount >= autoThreshold
        autoPaused = false
        sensing.resetLeg(); legStartAlt = sensing.altitudeM
    }

    /// Expected Δelevation for each leg, sampled from the offline DEM at the route
    /// nodes — lets the barometer confirm "we climbed like the map said" under the hood.
    private func expectedClimbPerLeg(_ r: Route) -> [Double] {
        guard let atlas else { return Array(repeating: 0, count: r.nodes.count) }
        func elev(_ n: RouteNode) -> Double {
            let p = atlas.meters(lat: n.lat, lon: n.lon); return atlas.dem.elevation(x: p.x, y: p.y) ?? 0
        }
        var out = [0.0]
        for k in 1..<r.nodes.count { out.append(elev(r.nodes[k]) - elev(r.nodes[k - 1])) }
        return out
    }

    /// True if the barometer change this leg matches the DEM's expected climb for a
    /// leg with clear relief — an under-the-hood arrival confirmation.
    private func slopeConfirms(idx: Int, now: Double) -> Bool {
        guard let e = engine, e.calibrated, idx < legExpectedClimb.count else { return false }
        let expected = legExpectedClimb[idx]
        guard abs(expected) >= 3, sensing.hasBarometer else { return false }      // only meaningful relief
        let observed = sensing.altitudeM - legStartAlt
        let tol = max(2.5, 0.45 * abs(expected))
        return (now - e.timeEnteredLeg) >= 3 && abs(observed - expected) <= tol && e.withinSnapRange()
    }

    /// Step 3 of the user's plan: with the ground-truth speed (distance ÷ time)
    /// now known, test whether the leg-1 sensor stream actually predicted it. If
    /// it did, let the sensors move the dot from here on; if not, stay honest.
    private func validateFirstLeg(distance: Double) {
        let r = calib.analyze(distanceM: distance)
        sensorPredictive = r.predictive
        if r.predictive {
            gait.observe(cadence: Double(r.stepCount) / max(r.seconds, 0.1), speed: r.groundTruthSpeed)
            persistStride()
            paceNote = String(format: "Pace learned: %.1f m/s · stride %.2f m · sensors predict speed (fit %.0f%%). Moving you by your steps.",
                              r.groundTruthSpeed, r.strideLength, r.predictability * 100)
        } else if r.groundTruthSpeed > 3 {
            // Few/no steps but covering ground fast ⇒ driving. Dead-reckon at the
            // measured speed; refine it (vs the road speed limit) each milestone.
            paceNote = String(format: "Driving pace set: %.0f m/s (≈%.0f mph). Moving you at your speed — refining each milestone.",
                              r.groundTruthSpeed, r.groundTruthSpeed * 2.237)
        } else {
            paceNote = String(format: "Pace set: %.1f m/s (steps weren’t steady, fit %.0f%%). Moving at your average pace.",
                              r.groundTruthSpeed, r.predictability * 100)
        }
        status = paceNote
        DebugLog.shared.log("nav.calibrate", ["predictive": r.predictive, "speed": r.groundTruthSpeed,
                                              "stride": r.strideLength, "fit": r.predictability,
                                              "steps": r.stepCount, "seconds": r.seconds])
    }

    /// Later legs refine the learned gait (only while we trust the sensors).
    private func refineGait(distance: Double, seconds: Double) {
        guard sensorPredictive, seconds > 0.5 else { return }
        let steps = sensing.legSteps
        guard steps >= 4 else { return }
        gait.observe(cadence: Double(steps) / seconds, speed: distance / seconds)
        persistStride()
    }

    /// Share the learned stride with the wilderness recovery walk (offline odometry).
    private func persistStride() {
        let s = gait.strideLength
        if s > 0.3 && s < 1.2 { UserDefaults.standard.set(s, forKey: "gaitStride") }
    }

    private func tick() {
        guard let e = engine, let r = route else { return }
        if e.isComplete { status = "🏁 Arrived."; approachLabel = ""; stopNav(); return }
        let now = Date().timeIntervalSince(t0)
        let m = sensing.state
        // Leg 1: record the sensor stream so we can validate it at the landmark.
        if !e.calibrated {
            calib.record(time: now, cumulativeSteps: sensing.legSteps)
        } else if sensorPredictive {
            // Walking with a good step signal: live stride×cadence pace.
            e.overrideSpeed(gait.predict(cadence: m.cadence) ?? 0)
        }
        // Otherwise (driving, or walking without a clean step signal) the engine
        // dead-reckons at the constant speed calibrated on leg 1, gated by motion.

        let legDist = e.nextMilestone.distanceFromPrior
        let legStart = e.timeEnteredLeg
        let ev = e.tick(now: now, isStationary: m.isStationary, isMoving: m.isMoving)

        if let ev, ev.automated {                       // engine auto-snapped on a real stop
            postEngineAdvance(legDist: legDist, legStart: legStart, now: now)
        } else {
            // Reached the milestone without stopping, or slope confirms arrival.
            let reachedGate = ev?.kind == .fallbackPrompt
            let auto = autoMode && !autoPaused && reachedGate
            if (auto || slopeConfirms(idx: e.currentIndex, now: now)), e.calibrated {
                doAdvance(now: now)
            }
        }
        let idx = e.currentIndex
        let base = (idx - 1 >= 0 && idx - 1 < r.nodes.count) ? r.nodes[idx - 1].cumulativeM : 0
        vehicle = positionAt(base + e.accumulatedDistance, total: r.totalDistanceM)
        if idx < r.nodes.count {
            nextMilestone = .init(latitude: r.nodes[idx].lat, longitude: r.nodes[idx].lon)
        } else { nextMilestone = nil }
        if follow, let v = vehicle { center = v }
        if now - lastNavLog >= 1.0, let v = vehicle {     // 1 Hz estimate, vs GPS truth in the log
            lastNavLog = now
            DebugLog.shared.log("nav.state", ["lat": v.latitude, "lon": v.longitude,
                                              "estSpeed": e.estimatedSpeed, "idx": idx,
                                              "accM": e.accumulatedDistance, "moving": !m.isStationary])
        }
        speed = (e.estimatedSpeed * 10).rounded() / 10
        cadence = (m.cadence * 10).rounded() / 10
        moving = m.isStationary ? "stopped" : "moving"
        headingText = m.hasMag ? String(format: "%.0f°", (m.headingDeg + headingOffset + 360).truncatingRemainder(dividingBy: 360)) : "—"
        nodeText = "\(idx)/\(r.milestones.count - 1)"
        if idx < r.milestones.count {
            let lim = r.milestones[idx].targetSpeedLimit
            limitText = lim > 0 ? "\(Int((lim * 2.237).rounded())) mph" : "—"
        }
        calibrated = e.calibrated
        approachLabel = label(for: idx, r)
        let remaining = e.remainingDistance()
        if !e.calibrated {
            approachDetail = "Walk here, then tap to set your pace"
        } else {
            approachDetail = remaining >= 1000
                ? String(format: "~%.1f km away", remaining / 1000)
                : "~\(Int(remaining.rounded())) m away"
        }
        if idx < r.nodes.count {
            turnArrow = arrowSymbol(forAngle: r.nodes[idx].turnAngle)
        } else { turnArrow = nil }
    }

    /// A directional arrow (SF Symbol) instead of "slight right ~43°" — point it
    /// the way to go. nil when it's basically straight ahead.
    private func arrowSymbol(forAngle a: Double) -> String? {
        if abs(a) < 15 { return nil }
        if a > 0 { return a > 50 ? "arrow.turn.up.right" : "arrow.up.right" }
        else     { return a < -50 ? "arrow.turn.up.left" : "arrow.up.left" }
    }

    private func label(for idx: Int, _ r: Route) -> String {
        guard idx < r.milestones.count else { return "" }
        let ms = r.milestones[idx]
        if ms.type == "destination" { return "Approaching your destination" }
        let word: String
        switch ms.type {
        case "stop_sign": word = "stop sign"
        case "traffic_light": word = "traffic light"
        case "crossing": word = "crossing"
        case "roundabout": word = "roundabout"
        default: word = "the intersection"
        }
        let on = (ms.name.isEmpty || ms.name == "unnamed road") ? "" : " on \(ms.name)"
        return "Approaching \(word)\(on)"
    }

    private func positionAt(_ traveled: Double, total: Double) -> CLLocationCoordinate2D? {
        guard routeCoords.count >= 2, routeCum.count == routeCoords.count,
              let last = routeCum.last, last > 0, total > 0 else { return routeCoords.first }
        let target = max(0, min(1, traveled / total)) * last
        for i in 1..<routeCum.count where routeCum[i] >= target {
            let seg = routeCum[i] - routeCum[i - 1]
            let t = seg <= 0 ? 0 : (target - routeCum[i - 1]) / seg
            let a = routeCoords[i - 1], b = routeCoords[i]
            return .init(latitude: a.latitude + (b.latitude - a.latitude) * t,
                         longitude: a.longitude + (b.longitude - a.longitude) * t)
        }
        return routeCoords.last
    }

    private func loadHome() {
        let d = UserDefaults.standard
        if d.object(forKey: "homeLat") != nil {
            home = .init(latitude: d.double(forKey: "homeLat"), longitude: d.double(forKey: "homeLon"))
        }
    }
    private func saveHome(_ c: CLLocationCoordinate2D) {
        UserDefaults.standard.set(c.latitude, forKey: "homeLat")
        UserDefaults.standard.set(c.longitude, forKey: "homeLon")
    }
}
