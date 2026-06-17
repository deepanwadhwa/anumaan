import Foundation
import CoreLocation
import Combine
import UIKit
import AnumaanCore

/// Drives the "I'm Lost" recovery protocol on-device: scatter ghosts over the
/// offline DEM, then for each straight walk siphon the barometer (elevation) +
/// locked compass heading, convert it to a distance profile via step odometry,
/// and feed it to the `RecoveryEngine` to cull the cloud toward a location lock.
@MainActor
final class RecoveryViewModel: ObservableObject {
    enum Phase { case loading, noData, ready, scattered, walking, locating, interrogate, located }

    @Published var phase: Phase = .loading
    @Published var status = ""
    @Published var ghostCount = 0
    @Published var lockedHeading = 0.0
    @Published var walkSteps = 0
    @Published var walkClimb = 0.0          // relative altitude change this walk (m)
    @Published var questionText = ""        // tie-breaker interrogation
    @Published var candidates: [CLLocationCoordinate2D] = []
    @Published var ghosts: [CLLocationCoordinate2D] = []     // subsampled cloud for the map
    @Published var located: CLLocationCoordinate2D?
    @Published var lockTentative = false          // true ⇒ "likely here" best guess, not a confident lock
    @Published var lockConfidence = 0.0           // 0…1 share of the cloud on the marker
    @Published var center = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    @Published var recenter = 0
    @Published var liveHeading = 0.0        // mirrored from the sensor so the view updates
    @Published var liveAltitude = 0.0
    @Published var liveMoving = false       // mirrored: moving vs stopped (red light / stop sign) for the drive HUD

    let sensing = SensingService()
    private var cancellables = Set<AnyCancellable>()
    private var atlas: Atlas?                                      // merged offline map (all patches)
    private var activeIndex: RoadIndex?                            // network to shape-match this walk (nil = off-trail)
    private var route: RouteMatcher?                              // graph map-matcher (road/trail); nil ⇒ off-trail terrain mode
    private let lockConc = 0.80                                   // lead must hold ≥80% to lock (a 69% lock was 3.5 km wrong)
    private var session: RecoverySession?                          // headless interrogation loop (AnumaanCore)

    enum Surface { case road, trail, offtrail, driving }
    private var matcher: CurveMatcher?      // deterministic curve-on-map matcher (no wandering filter)
    private let profileStep = 30.0
    private var stride = 0.75                // m/step (DTW absorbs the residual error)
    // One continuous track for the whole recovery session (synced samples), so
    // multiple walks + the turns between them fuse into a single fingerprint.
    private var pathDist: [Double] = []
    private var pathAlt: [Double] = []
    private var pathHeading: [Double] = []
    private var pathTime: [Double] = []           // seconds since walk start (driving uses time, not steps)
    private var pathMoving: [Bool] = []           // was the car moving this sample? (skip red lights)
    private var walkStartAlt = 0.0
    private var walkStartTime = Date()
    // Suspension guard: if iOS suspends the app mid-walk, CoreMotion (heading)
    // stops but CMPedometer back-fills its step count on resume. Recording that
    // catch-up as forward motion fabricates a long straight-line segment at the
    // wrong heading (a 253 s sleep once injected a fake 336 m leg). We detect the
    // wall-clock gap, exclude the unobserved distance, and flag the walk.
    private var lastSampleWall: Date?
    private var distSkip = 0.0                      // distance dropped across suspension gaps
    @Published var sensorGapSeconds = 0.0          // total time the phone slept during this walk (>0 ⇒ unreliable)
    @Published var walkWarning = ""                // shown to the user when a walk's data is compromised (e.g. phone slept)
    @Published var driveSeconds = 0.0              // elapsed time on the current DRIVE (driving uses time, not steps)
    @Published private(set) var driving = false    // current recovery is in a car (speed-limit map-matching)
    private var natureMode = false                 // trail / off-trail ⇒ ask about woods/water/terrain, NOT roads
    private var timer: Timer?
    private var lastHeadings: [Double] = []
    private var endOffset = GeoPoint(x: 0, y: 0)   // walk displacement: ghost start → current spot
    private var lastRotation = 0.0                 // road-fit rotation chosen this walk (for the log)
    private var lastPeak = 0.0
    private var headingOffset = 0.0                // magnetic→true (WMM declination, +east)

    // The interrogation's active question + question bank now live in the headless
    // `RecoverySession` (AnumaanCore); this view model just renders its decisions.

    // Positive identification — name a street/landmark you can actually see.
    @Published var nameQuery = ""
    @Published var nameSuggestions: [String] = []
    @Published var coverageRects: [[CLLocationCoordinate2D]] = []   // downloaded-area outlines

    init() {
        sensing.start()
        // Mirror sensor heading/altitude into @Published so the view refreshes live.
        sensing.$state
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.liveHeading = $0.headingDeg; self?.liveMoving = $0.isMoving }
            .store(in: &cancellables)
        sensing.$altitudeM
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.liveAltitude = $0 }
            .store(in: &cancellables)
        let s = UserDefaults.standard.double(forKey: "gaitStride")   // learned on the Navigate tab
        if s > 0.3 && s < 1.2 { stride = s }
        status = "Loading offline maps…"
        loadArea()
    }

    /// Decode the saved area OFF the main thread (it's a multi-MB blob), so opening
    /// this tab never freezes the UI. Cached after the first load.
    private func loadArea() {
        Task { [weak self] in
            let a = await Atlas.build()
            guard let self else { return }
            if let a {
                self.atlas = a
                self.session = RecoverySession(map: Self.interrogationMap(a))
                self.coverageRects = a.coverage.map { b in
                    [CLLocationCoordinate2D(latitude: b.s, longitude: b.w),
                     .init(latitude: b.s, longitude: b.e), .init(latitude: b.n, longitude: b.e),
                     .init(latitude: b.n, longitude: b.w), .init(latitude: b.s, longitude: b.w)]
                }
                let c = a.center
                self.headingOffset = GeoMagnetism.declination(latDeg: c.latitude, lonDeg: c.longitude,
                                                              year: AppTime.decimalYear())
                self.sensing.declinationOffset = self.headingOffset
                self.center = c; self.recenter += 1
                self.phase = .ready
                self.status = "Offline maps ready (\(a.patches.count) area\(a.patches.count == 1 ? "" : "s")). Tap “I’m Lost” to start."
            } else {
                self.phase = .noData
                self.status = "No offline maps yet. On the Navigate tab, download an area first."
            }
        }
    }

    private func scatterRadius() -> Double { atlas?.radiusM ?? 1000 }

    // Search-area constraint. Without this the matcher seeds across the ENTIRE
    // downloaded atlas (every city you've saved), so a walk can "find" you in the
    // wrong town. We bound the search to the map region you're framing when you
    // start: pan/zoom to roughly where you are, and we only look there.
    private var searchBounds: (s: Double, w: Double, n: Double, e: Double)?
    @Published var searchAreaSet = false                 // drives the UI hint
    /// Called by the map as you pan/zoom; we snapshot it at walk start.
    func setVisibleRegion(s: Double, w: Double, n: Double, e: Double) {
        // Ignore a near-global frame (you zoomed way out) — that's "search everywhere".
        searchBounds = (n - s > 1.2 || e - w > 1.2) ? nil : (s, w, n, e)
        searchAreaSet = searchBounds != nil
    }
    /// True ⇒ point is outside the framed search area. Static + parameterised so the
    /// seed-mask closures can run on a background thread without touching the actor.
    nonisolated static func outside(_ p: GeoPoint,
                                    _ bounds: (s: Double, w: Double, n: Double, e: Double)?,
                                    _ atlas: Atlas) -> Bool {
        guard let b = bounds else { return false }
        let ll = atlas.latLon(x: p.x, y: p.y)
        return ll.lat < b.s || ll.lat > b.n || ll.lon < b.w || ll.lon > b.e
    }
    private func outsideSearch(_ p: GeoPoint) -> Bool {
        guard let atlas else { return false }
        return Self.outside(p, searchBounds, atlas)
    }

    // The "impossible location" predicate for the CURRENT route surface (water +
    // any surface exclusion + the framed search area). Stored so the re-seed inside
    // finishWalkRoute/Drive applies the SAME constraints — otherwise the search-area
    // and trail masks set at walk-start get wiped right before matching.
    private var routeSeedMask: ((GeoPoint) -> Bool)?
    /// Re-seed the route cloud and re-apply every active mask.
    private func seedRouteMasked(_ count: Int) {
        guard let route else { return }
        route.seed(targetCount: count)
        if let m = routeSeedMask { route.mask(m) }
    }

    /// "I'm Lost": reset. The candidate spots are dropped when you pick a surface
    /// (paved road / trail / off-trail) on the first walk.
    func panic() {
        guard let atlas else { return }
        matcher = nil; route = nil; ghostCount = 0
        candidates = []; located = nil; ghosts = []
        pathDist = []; pathAlt = []; pathHeading = []; pathTime = []; pathMoving = []; lastHeadings = []
        endOffset = GeoPoint(x: 0, y: 0); driving = false; natureMode = false
        phase = .scattered
        status = "First — paved road, trail, or off-trail? Pick one, then walk a distinctive path (with TURNS)."
        DebugLog.shared.sessionStart("recover", owner: sensing)   // only this sensing logs
        DebugLog.shared.log("recover.panic", ["radiusM": scatterRadius(), "declination": headingOffset,
                                              "hasRoads": !atlas.roads.isEmpty, "hasTrails": atlas.trails != nil])
    }

    /// A REGULAR grid of candidate start points over the search disc — never random,
    /// so your true position always has a candidate within ~½ the spacing (no gaps),
    /// and the elevation-contour match runs from every one. Spacing is chosen for
    /// ~`targetCount` points; never finer than the 30 m DEM (no point going below it).
    private func scatterGrid(targetCount: Int) -> [GeoPoint] {
        let r = scatterRadius()
        let spacing = max(28.0, (.pi * r * r / Double(max(1, targetCount))).squareRoot())
        var out: [GeoPoint] = []
        var y = -r
        while y <= r {
            var x = -r
            while x <= r {
                if x * x + y * y <= r * r { out.append(GeoPoint(x: x, y: y)) }
                x += spacing
            }
            y += spacing
        }
        return out
    }

    /// Walk on the chosen surface. The FIRST walk drops the candidate spots:
    /// road/trail ⇒ only on that network (a huge prior, and we curve-match it);
    /// off-trail ⇒ anywhere on the terrain (no road shape — lean on relief + Qs).
    func walk(_ surface: Surface) {
        guard let atlas else { return }
        if pathDist.isEmpty {                                   // fresh session: build the hypothesis set
            sensing.resetLeg(); walkStartAlt = sensing.altitudeM; walkStartTime = Date()
            pathDist = []; pathAlt = []; pathHeading = []; pathTime = []; pathMoving = []
            walkSteps = 0; walkClimb = 0
            activeIndex = nil; driving = false; natureMode = false
            switch surface {
            case .road:
                // Snap the walk onto the actual street network (heading + elevation).
                let g = atlas.roadGraphMeters()
                let rm = RouteMatcher(nodes: g.nodes, adjacency: g.adjacency, dem: atlas.dem)
                route = rm; matcher = nil
                let bounds = searchBounds
                routeSeedMask = { p in
                    atlas.features.containing([.water], point: p) != nil || Self.outside(p, bounds, atlas)
                }
                seedRouteMasked(6000); ghostCount = rm.walkerCount   // display preview only; finishWalk re-seeds 15000 off-main
            case .trail:
                natureMode = true
                // Snap onto the TRAIL network if this area actually has one mapped;
                // otherwise match the TERRAIN (never silently fall back to roads —
                // a trail walk doesn't lie on streets).
                if let g = atlas.trailGraphMeters(), g.nodes.count >= 30 {
                    let rm = RouteMatcher(nodes: g.nodes, adjacency: g.adjacency, dem: atlas.dem)
                    route = rm; matcher = nil
                    let bounds = searchBounds
                    routeSeedMask = { p in
                        atlas.features.containing([.water], point: p) != nil
                            || atlas.roads.nearestDistance(to: p) <= 20      // trail walkers NEVER on a road
                            || Self.outside(p, bounds, atlas)
                    }
                    seedRouteMasked(6000); ghostCount = rm.walkerCount   // display preview only; finishWalk re-seeds 15000 off-main
                } else {
                    let cands = scatterGrid(targetCount: 15000)
                    let m = CurveMatcher(dem: atlas.dem, roads: nil, candidates: cands)
                    m.maskOut { atlas.features.containing([.water], point: $0) != nil }
                    m.maskOut { atlas.roads.nearestDistance(to: $0) <= 20 }   // you said TRAIL → you're NOT on a paved road
                    matcher = m; route = nil; ghostCount = cands.count
                }
            case .driving:
                // Same map-matching, but each hypothesis advances at its road's
                // speed limit × time (no steps in a car). EXPERIMENTAL.
                let g = atlas.drivingGraphMeters()
                let rm = RouteMatcher(nodes: g.nodes, adjacency: g.adjacency, dem: atlas.dem, edgeSpeedsMps: g.speeds)
                rm.headingSigmaDeg = 35              // a phone in a cup-holder wanders more than in-hand
                route = rm; matcher = nil; driving = true
                let bounds = searchBounds
                routeSeedMask = { p in
                    atlas.features.containing([.water], point: p) != nil || Self.outside(p, bounds, atlas)
                }
                seedRouteMasked(6000); ghostCount = rm.walkerCount   // display preview only; finishWalk re-seeds 15000 off-main
            case .offtrail:
                natureMode = true
                // No roads to snap to → contour-match the relief from a REGULAR grid
                // of start points (dense enough that you're never between candidates).
                let cands = scatterGrid(targetCount: 15000)
                let m = CurveMatcher(dem: atlas.dem, roads: nil, candidates: cands)
                m.maskOut { atlas.features.containing([.water], point: $0) != nil }
                m.maskOut { atlas.roads.nearestDistance(to: $0) <= 20 }   // off-trail → you're NOT on a paved road
                matcher = m; route = nil; ghostCount = cands.count
            }
            // Bound the terrain matcher to the framed area too (route clouds already
            // carry it via routeSeedMask).
            if searchBounds != nil { matcher?.maskOut { self.outsideSearch($0) } }
            snapshotGhosts()
        }
        beginSampling()
        switch surface {
        case .road:     status = "Walking on roads. Turns and curves snap it onto the street fastest. Tap “Find me” when you’ve covered ground."
        case .trail:    status = route != nil
            ? "On the mapped trail network. Turns + elevation narrow it. Tap “Find me” when you’ve covered ground."
            : "No trails are mapped here — matching the TERRAIN instead (candidates kept off paved roads). Walk a hilly, turning path, then “Find me”."
        case .offtrail: status = "Walking off-trail. Climbs, dips and turns help. Tap “Find me” when you’ve covered ground."
        case .driving:  status = "Driving. Make some turns and keep the phone steady. Tap “Find me” after a few minutes / a couple of turns."
        }
        DebugLog.shared.log("recover.walk", ["surface": "\(surface)", "mode": driving ? "drive" : (route != nil ? "route" : "terrain")])
    }

    /// Resample the accumulated walk into fixed-`step` bins of (heading, cumulative
    /// barometer elevation) — the observation sequence the route matcher replays.
    private func resampleWalk(step: Double) -> (headings: [Double], cumElev: [Double]) {
        guard let last = pathDist.last, last >= step, pathDist.count == pathHeading.count else { return ([], []) }
        var headings: [Double] = [], elev: [Double] = []
        var target = step, i = 0
        while target <= last {
            while i < pathDist.count - 1 && pathDist[i] < target { i += 1 }
            headings.append(pathHeading[i]); elev.append(pathAlt[i])
            target += step
        }
        return (headings, elev)
    }

    private func beginSampling() {
        phase = .walking
        lastSampleWall = nil; walkWarning = ""
        // Keep the screen awake AND the process scheduled in the background so iOS
        // can't suspend us mid-walk and strangle the CoreMotion heading stream.
        UIApplication.shared.isIdleTimerDisabled = true
        sensing.startBackgroundKeepAlive()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    /// Stop the walk sampler and release the keep-awake holds.
    private func endSampling() {
        timer?.invalidate(); timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        sensing.stopBackgroundKeepAlive()
    }

    private func sample() {
        walkSteps = sensing.legSteps
        walkClimb = sensing.altitudeM - walkStartAlt
        // Pace-adaptive distance (handles running); fall back to steps×stride only
        // if the device doesn't report pedometer distance.
        let rawDist = sensing.hasPedometerDistance ? sensing.legDistanceM : Double(walkSteps) * stride

        // Suspension guard. The timer fires every 0.5 s; a much larger wall-clock
        // gap means the app was suspended (screen lock / pocket) and CoreMotion
        // went dark. The pedometer's back-filled distance over that gap has NO
        // heading behind it — so we DON'T advance the path through it (that would
        // fabricate a straight leg). We add the unobserved jump to `distSkip` so
        // the path stays continuous, and record how long we were blind.
        let now = Date()
        if let last = lastSampleWall, now.timeIntervalSince(last) > 3.0 {
            let jump = rawDist - distSkip - (pathDist.last ?? 0)
            if jump > 0 { distSkip += jump }
            sensorGapSeconds += now.timeIntervalSince(last)
        }
        lastSampleWall = now

        pathDist.append(rawDist - distSkip)
        pathAlt.append(walkClimb)
        pathHeading.append(sensing.state.headingDeg + headingOffset)   // → true north for DEM sampling
        let elapsed = Date().timeIntervalSince(walkStartTime)
        pathTime.append(elapsed)
        pathMoving.append(sensing.state.isMoving)
        if driving { driveSeconds = elapsed }
    }

    /// End the walk: fold the path's shape into the cloud (where there's relief),
    /// update our position offset, then resume the guess-who questions.
    func finishWalk() {
        // Re-entry guard. Matching runs on a background task; if the button stayed
        // live the user could tap it again and a SECOND task would mutate the same
        // hypothesis cloud concurrently → crash. Only proceed from an active walk.
        guard phase == .walking else { return }
        phase = .locating
        endSampling()
        // If the phone slept during the walk, CoreMotion went dark and part of the
        // turn/heading sequence was never recorded — say so instead of quietly
        // returning a guess built on a hole in the data.
        walkWarning = sensorGapSeconds > 5
            ? String(format: "⚠️ Your phone slept for %.0fs during this walk, so part of your path wasn’t recorded — this guess may be off. Keep the app open and the screen on, and walk again.", sensorGapSeconds)
            : ""
        if driving { finishWalkDrive(); return }
        if route != nil { finishWalkRoute(); return }
        guard let m = matcher else { phase = .scattered; return }
        let (profile, headings) = PathSiphon.build(distances: pathDist, altitudes: pathAlt,
                                                   headings: pathHeading, step: profileStep)
        if headings.count >= 3 {
            var corrected = headings
            // Small tilt correction only (the declination-corrected compass is good).
            if let ri = activeIndex, !ri.isEmpty {
                let est = ri.estimateRotation(candidates: sampleGhostPoints(max: 600),
                                              headings: headings, step: profileStep, tolerance: 25)
                lastRotation = est.rotation; lastPeak = est.peak
                if est.peak >= 0.6 { corrected = headings.map { $0 + est.rotation } }
            }
            lastHeadings = corrected
            endOffset = pathEndOffset(corrected)
            // Score every fixed candidate by the WHOLE curve so far: road shape × slope.
            m.scorePath(headings: corrected, profile: profile)
        }
        afterWalkDecision()
    }

    /// Road/trail: re-run the graph map-matcher over the WHOLE walk so far, then
    /// lock or guide. Walkers end at your CURRENT position — no offset needed.
    private func finishWalkRoute() {
        guard let route else { return }
        let step = 15.0
        let (headings, cum) = resampleWalk(step: step)
        guard headings.count >= 3 else { promptWalk(); return }
        lastHeadings = headings
        let mask = routeSeedMask
        status = "Pinpointing your location…"
        Task.detached(priority: .userInitiated) {
            route.seed(targetCount: 15000)
            if let mask { route.mask(mask) }
            for i in headings.indices { route.advance(distanceM: step, headingDeg: headings[i], cumElevM: cum[i]) }
            await MainActor.run { [weak self] in
                self?.afterWalkDecisionRoute()
            }
        }
    }

    /// EXPERIMENTAL driving recovery: there are no steps in a car, so we bin the
    /// drive by TIME and advance each hypothesis at its road's speed limit. We don't
    /// know how fast you actually drove vs the posted limit, so we SEARCH a global
    /// speed scale and keep whichever makes the cloud agree most tightly.
    private func finishWalkDrive() {
        guard let route else { return }
        let binSec = 4.0
        let bins = resampleDriveBins(binSec: binSec)
        guard bins.count >= 3 else { promptWalk(); return }
        lastHeadings = bins.map { $0.heading }
        let mask = routeSeedMask
        status = "Pinpointing your location…"
        Task.detached(priority: .userInitiated) {
            func replay(_ scale: Double, seeds: Int) -> Double {
                route.seed(targetCount: seeds)
                if let mask { route.mask(mask) }
                for b in bins where b.moving {
                    route.advanceDriving(seconds: binSec, headingDeg: b.heading, cumElevM: b.cumElev, speedScale: scale)
                }
                return route.summary(radiusM: 150)?.concentration ?? 0
            }
            // Per-segment limits are in the graph; this global factor absorbs how close
            // to the limit you drive. Coarse search, then one full-resolution run.
            var searchScale = 1.0, searchConc = -1.0
            for sc in [0.85, 1.0, 1.15] {
                let c = replay(sc, seeds: 3000)
                if c > searchConc { searchConc = c; searchScale = sc }
            }
            _ = replay(searchScale, seeds: 15000)
            // Hand the main actor IMMUTABLE copies (a captured `var` crossing the
            // concurrency boundary is a Swift-6 error).
            let bestScale = searchScale, bestConc = searchConc
            await MainActor.run { [weak self] in
                DebugLog.shared.log("recover.drivescale", ["scale": bestScale, "conc": bestConc, "bins": bins.count])
                self?.afterWalkDecisionRoute()
            }
        }
    }

    /// Resample the drive into fixed `binSec` bins of (heading, cumulative elevation,
    /// moving?) — stopped bins (red lights) advance no one.
    private func resampleDriveBins(binSec: Double) -> [(heading: Double, cumElev: Double, moving: Bool)] {
        guard let last = pathTime.last, last >= binSec, pathTime.count == pathHeading.count else { return [] }
        var out: [(heading: Double, cumElev: Double, moving: Bool)] = []
        var target = binSec, i = 0
        while target <= last {
            while i < pathTime.count - 1 && pathTime[i] < target { i += 1 }
            out.append((pathHeading[i], pathAlt[i], pathMoving[i]))
            target += binSec
        }
        return out
    }

    private func afterWalkDecisionRoute() {
        guard let route, let atlas else { return }
        snapshotGhosts()
        let retrace = pathRetrace(lastHeadings)
        guard let sm = route.summary(radiusM: 120) else {
            phase = .scattered; status = "Walk a bit further, then tap “Find me”."; return
        }
        let ll = atlas.latLon(x: sm.estimate.x, y: sm.estimate.y)
        DebugLog.shared.log("recover.findme", ["candidates": sm.areas, "estLat": ll.lat, "estLon": ll.lon,
                                               "distM": pathDist.last ?? 0, "bins": lastHeadings.count,
                                               "conc": sm.concentration, "retrace": retrace,
                                               "walkers": route.walkerCount, "mode": "route",
                                               "sensorGapSec": sensorGapSeconds])
        if retrace > 0.5 && sm.concentration < lockConc {
            phase = .scattered
            status = "You’re mostly retracing the same ground — walk a NEW direction with a couple of TURNS, then tap “Find me”."
            return
        }
        // NEVER lock straight from a walk — verify the guess with a question first
        // (on <road>? at an intersection? near water?). A wrong guess gets refuted.
        renderStartRound()
    }

    private func sampleGhostPoints(max n: Int) -> [GeoPoint] {
        let cs = matcher?.candidates ?? []
        guard !cs.isEmpty else { return [] }
        let stepN = Swift.max(1, cs.count / n)
        return cs.enumerated().filter { $0.offset % stepN == 0 }.map { $0.element }
    }

    /// After narrowing by a walk: lock if we're there; play guess-who once the
    /// shortlist is reasonable; otherwise keep walking.
    /// A candidate is a walk START; the person is now at START + endOffset. Always
    /// display / lock / report this CURRENT spot, never the start.
    private func current(_ start: GeoPoint) -> GeoPoint {
        GeoPoint(x: start.x + endOffset.x, y: start.y + endOffset.y)
    }

    private func afterWalkDecision() {
        guard let m = matcher else { return }
        snapshotGhosts()
        let candidates = m.candidateCount(radiusM: 150, coverage: 0.85)
        let retrace = pathRetrace(lastHeadings)
        let conc = m.leadConcentration(radiusM: 120)
        let here = current(m.lead)
        if let atlas {
            let ll = atlas.latLon(x: here.x, y: here.y)
            DebugLog.shared.log("recover.findme", ["candidates": candidates, "estLat": ll.lat,
                                                   "estLon": ll.lon, "distM": pathDist.last ?? 0,
                                                   "bins": lastHeadings.count, "rot": lastRotation,
                                                   "peak": lastPeak, "retrace": retrace, "conc": conc])
        }
        let walked = pathDist.last ?? 0
        // Honest failure: after a real walk the cloud is still spread thin ⇒ the
        // terrain + roads here look the same in many places. Don't fake a lock —
        // steer to a positive ID, which is the only thing that pins a generic area.
        if walked > 350 && conc < 0.15 && candidates > 20 {
            phase = .scattered
            status = "The roads and terrain here look the same in ~\(candidates) places, so walking alone can’t pin you. If you can see ANY street sign, shop, or trail marker, type it below — that locks it instantly."
            return
        }
        if retrace > 0.5 && conc < lockConc {
            phase = .scattered
            status = "You’re mostly retracing the same ground (≈\(Int(retrace * 100))%). That can’t place you — walk a NEW direction and make a couple of TURNS, then tap “Find me”."
            return
        }
        // NEVER lock straight from a walk — always verify the guess with a question first.
        renderStartRound()
    }

    /// Net displacement of the binned path (each bin advances one DEM step along
    /// its heading) — ghost START + this = the ghost's CURRENT spot, where the
    /// "what's next to you" questions are evaluated.
    private func pathEndOffset(_ headings: [Double]) -> GeoPoint {
        var x = 0.0, y = 0.0
        for h in headings { let r = h * .pi / 180; x += sin(r) * profileStep; y += cos(r) * profileStep }
        return GeoPoint(x: x, y: y)
    }

    /// Fraction of the path that revisits earlier ground — high ⇒ back-and-forth /
    /// pacing the same line, which carries almost no localizing information.
    private func pathRetrace(_ headings: [Double]) -> Double {
        guard headings.count >= 6 else { return 0 }
        var pts: [GeoPoint] = []; var x = 0.0, y = 0.0
        for h in headings { let r = h * .pi / 180; x += sin(r) * profileStep; y += cos(r) * profileStep
                            pts.append(GeoPoint(x: x, y: y)) }
        var revisits = 0
        for i in 4..<pts.count {
            for j in 0..<(i - 3) {
                let dx = pts[i].x - pts[j].x, dy = pts[i].y - pts[j].y
                if dx * dx + dy * dy <= 25 * 25 { revisits += 1; break }
            }
        }
        return Double(revisits) / Double(pts.count)
    }

    /// Subsample the LIVE particle cloud (weight > 0, so masked/lake ghosts don't
    /// show) to ≤1500 points for an efficient map overlay.
    private func snapshotGhosts() {
        // Route walkers are already at the CURRENT position; curve candidates are
        // walk STARTS, so shift those by the walk offset.
        let pts: [GeoPoint] = route?.livePositions ?? (matcher?.live() ?? []).map(current)
        guard !pts.isEmpty else { ghosts = []; return }
        let stepN = max(1, pts.count / 1500)
        ghosts = pts.enumerated().filter { $0.offset % stepN == 0 }.map { coord($0.element) }
    }

    // MARK: Guess Who — drive the headless RecoverySession (AnumaanCore)

    /// The merged offline map's interrogation data in core's local-meter frame.
    private static func interrogationMap(_ a: Atlas) -> InterrogationMap {
        InterrogationMap(features: a.features, dem: a.dem,
                         landmarks: a.landmarks,
                         namedRoads: a.namedRoadSegs.map { (name: $0.key, segments: $0.value) },
                         pois: a.pois)
    }

    /// The current hypotheses as a unified, current-position cloud the session can
    /// interrogate: the road/trail walkers, or the off-trail curve candidates
    /// (shifted by the walk offset). nil before the first walk drops candidates.
    private func cloud() -> HypothesisCloud? {
        if let route { return RouteCloud(route) }
        if let m = matcher { return CurveCloud(m, endOffset: endOffset) }
        return nil
    }

    /// Begin a fresh interrogation round (after a walk, a downhill prune, a named
    /// pick, or a rejection) and render the session's first decision.
    private func renderStartRound() {
        guard let session, let c = cloud() else { promptWalk(); return }
        render(session.startRound(cloud: c, natureMode: natureMode, heading: lastHeadings.last))
    }

    /// Map a session decision onto the UI: ask the next question, lock, or walk more.
    private func render(_ outcome: RecoverySession.Outcome) {
        snapshotGhosts()
        switch outcome {
        case .ask(let q):
            questionText = q.text
            phase = .interrogate
            status = q.named
                ? "Quick check before I commit — answer about what you can actually see:"
                : "Look around and answer — this confirms or rules out where I think you are."
            DebugLog.shared.log("recover.question", ["text": q.text, "named": q.named])
        case .located(let p, let confident, let conc):
            locate(p, confident: confident, conc: conc)
        case .needWalk:
            promptWalk()
        }
    }

    /// Apply the human's yes/no to the active question, prune the cloud, re-decide.
    func answer(yes: Bool) {
        guard let session, let q = session.active, let c = cloud() else { return }
        DebugLog.shared.log("recover.answer", ["text": q.text, "yes": yes, "named": q.named])
        render(session.answer(yes, cloud: c))
    }

    /// "Can't tell": drop the active question and decide with what we have.
    func skipQuestion() {
        guard let session, let c = cloud() else { return }
        questionText = ""
        render(session.skip(cloud: c))
    }

    /// "Point your phone downhill and tap": the true bearing the phone faces IS the
    /// downhill direction. Keep candidates whose terrain falls the same way (flat
    /// candidates abstain). One reading prunes hard — everyone always knows downhill.
    func markDownhill() {
        guard let atlas, (matcher != nil || route != nil) else {
            status = "Walk a little first — point downhill once there are candidate areas on the map to narrow."
            return
        }
        let h = sensing.state.headingDeg + headingOffset      // → true north
        let dem = atlas.dem
        let dir = Interrogation.name(forHeading: h)           // "NW", "East", …
        let keep: (GeoPoint) -> Bool = { here in
            guard let sa = dem.slopeAspect(at: here) else { return false }
            if sa.slopeDeg < 4 { return true }                // ~flat: can't disagree, don't penalize
            return bearingDelta(sa.downhillDeg, h) <= 50
        }
        if let route {                                        // road/trail map-matcher
            route.constrain(keep: keep, soft: 0.25)
        } else if let m = matcher {                            // off-trail terrain matcher
            m.constrain(endOffset: endOffset, hard: false, keep: keep)
        }
        DebugLog.shared.log("recover.downhill", ["heading": h, "dir": dir, "mode": route != nil ? "route" : "terrain"])
        // Fold it in, then verify with a question before any lock (never auto-lock).
        renderStartRound()
    }

    // The question bank, named-question generation, and the ask/lock decision now
    // live in AnumaanCore's `RecoverySession` (see `render` / `answer` above).

    // MARK: positive identification — far stronger than a string of "no"s

    func updateNameSuggestions(_ q: String) {
        nameQuery = q
        let ql = q.lowercased()
        guard ql.count >= 2, let atlas else { nameSuggestions = []; return }
        var names = Set(atlas.namedRoadSegs.keys)
        for p in atlas.pois { names.insert(p.name) }
        nameSuggestions = Array(names.filter { $0.lowercased().contains(ql) }.sorted().prefix(8))
    }

    /// You named a street/landmark you can see → hard-constrain the cloud to its
    /// vicinity. One positive ID localizes far better than eliminating streets.
    func pickName(_ name: String) {
        guard let atlas else { return }
        let segs = atlas.namedRoadSegs[name]
        let poiPt = atlas.pois.first(where: { $0.name == name })?.p
        let pred: ((GeoPoint) -> Bool)? = {
            if let segs { return { p in segs.contains { Geo.pointToSegment(p, $0.0, $0.1).0 <= 70 } } }
            if let poiPt { return { p in hypot(p.x - poiPt.x, p.y - poiPt.y) <= 70 } }
            return nil
        }()

        if let route, let pred {                   // road/trail: hard-filter the walkers near the named feature
            route.constrain(keep: pred, soft: 0)
            DebugLog.shared.log("recover.named", ["name": name, "mode": "route"])
            nameQuery = ""; nameSuggestions = []; snapshotGhosts()
            if let sm = route.summary(radiusM: 120), sm.concentration >= 0.6 { locate(sm.estimate, conc: sm.concentration) }
            else { renderStartRound() }   // narrowed near the sign → keep disambiguating
            return
        }

        if let m = matcher {                       // mid-recovery: hard-constrain the cloud
            var pred: ((GeoPoint) -> Bool)?
            if let segs {
                pred = { p in for s in segs where Geo.pointToSegment(p, s.0, s.1).0 <= 70 { return true }; return false }
            } else if let poiPt {
                pred = { p in hypot(p.x - poiPt.x, p.y - poiPt.y) <= 70 }
            }
            guard let pred else { return }
            m.constrain(endOffset: endOffset, hard: true) { here in pred(here) }   // positive ID ⇒ hard
            DebugLog.shared.log("recover.named", ["name": name])
            nameQuery = ""; nameSuggestions = []
            renderStartRound()
        } else {                                   // no walk yet — they just read a sign: snap to it
            var p: GeoPoint?
            if let poiPt { p = poiPt }
            else if let segs, !segs.isEmpty {
                var sx = 0.0, sy = 0.0, n = 0.0
                for s in segs { sx += (s.0.x + s.1.x) / 2; sy += (s.0.y + s.1.y) / 2; n += 1 }
                p = GeoPoint(x: sx / n, y: sy / n)
            }
            guard let p else { return }
            DebugLog.shared.log("recover.named", ["name": name, "noTrack": true])
            nameQuery = ""; nameSuggestions = []
            locate(p, conc: 1.0)
        }
    }

    /// "Not here" on the lock screen: kill the rejected spot (and everything near
    /// it) and resume narrowing — don't make the user start over from scratch.
    func rejectLock() {
        guard let here = located, let atlas else { reset(); return }
        let bad = atlas.meters(lat: here.latitude, lon: here.longitude)
        located = nil
        DebugLog.shared.log("recover.reject", ["lat": here.latitude, "lon": here.longitude])
        if let route {
            route.mask { $0.distance(to: bad) <= 300 }                 // walkers are at current pos
            if route.walkerCount == 0 {
                status = "Okay — that was wrong, and I’m out of road hypotheses here. Walk a NEW direction with a turn, then tap “Find me”."
                phase = .scattered; snapshotGhosts(); return
            }
        } else if let m = matcher {
            m.maskOut { GeoPoint(x: $0.x + endOffset.x, y: $0.y + endOffset.y).distance(to: bad) <= 300 }
        }
        status = "Got it — not there. Let me narrow it down again."
        renderStartRound()
    }

    /// Place the marker. `confident` = the cloud strongly agrees (a real lock);
    /// otherwise it's our best guess after asking everything we could — shown as
    /// "likely here", with the confidence so the person knows how much to trust it.
    private func locate(_ p: GeoPoint, confident: Bool = true, conc: Double = 0) {
        lockConfidence = conc
        lockTentative = !confident
        located = coord(p); candidates = []
        center = located!; recenter += 1
        phase = .located
        let pct = Int((lockConfidence * 100).rounded())
        status = confident
            ? "Location lock. You’re at the marker — confirm against what you can see."
            : "Best guess: you’re LIKELY here (~\(pct)% sure). Walk a little more to confirm, or tap “Not here”."
        DebugLog.shared.log("recover.lock", ["lat": located!.latitude, "lon": located!.longitude,
                                              "confident": confident, "conc": lockConfidence])
    }

    /// "Walk more to confirm" from the best-guess screen — resume the same walk.
    func walkMore() {
        located = nil; phase = .scattered; snapshotGhosts()
        status = "Keep walking — a turn or a hill sharpens it — then tap “Find me”."
    }

    private func promptWalk() {
        snapshotGhosts()
        phase = .scattered
        let n = route?.summary(radiusM: 120)?.areas ?? matcher?.candidateCount(radiusM: 150, coverage: 0.85) ?? 0
        status = hasTrack
            ? "About \(n) possible areas left, and I’m out of useful questions here. Walk a bit more — a turn or a hill helps — or type a sign you can see, then tap “Find me”."
            : "Walk ~80–100 steps (a turn or a slope helps), then tap “Find me”."
    }

    var hasTrack: Bool { !pathDist.isEmpty }

    func reset() {
        endSampling()
        phase = atlas == nil ? .noData : .ready; candidates = []; located = nil; ghosts = []
        questionText = ""; session?.reset(); matcher = nil; route = nil
        nameQuery = ""; nameSuggestions = []
        pathDist = []; pathAlt = []; pathHeading = []; pathTime = []; pathMoving = []
        lastHeadings = []; endOffset = GeoPoint(x: 0, y: 0); driving = false; natureMode = false
        lastSampleWall = nil; distSkip = 0; sensorGapSeconds = 0
        status = "Ready."
    }

    private func coord(_ p: GeoPoint) -> CLLocationCoordinate2D {
        guard let atlas else { return .init(latitude: 0, longitude: 0) }
        let ll = atlas.latLon(x: p.x, y: p.y)
        return .init(latitude: ll.lat, longitude: ll.lon)
    }
}
