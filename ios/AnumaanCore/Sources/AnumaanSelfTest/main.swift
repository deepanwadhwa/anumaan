import Foundation
import AnumaanCore

// Plain-assertion self-test (no XCTest, so it runs with just the Swift toolchain).
var passed = 0, failed = 0
func check(_ cond: Bool, _ name: String) {
    if cond { passed += 1 } else { failed += 1; print("  ✗ FAIL: \(name)") }
}
func near(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) <= eps }

func simpleRoute() -> [Milestone] {
    [Milestone(id: "o", type: "origin", distanceFromPrior: 0),
     Milestone(id: "a", type: "stop_sign", distanceFromPrior: 100, name: "A"),
     Milestone(id: "b", type: "intersection", distanceFromPrior: 200, name: "B"),
     Milestone(id: "c", type: "destination", distanceFromPrior: 300, name: "Dest")]
}

// Rule 1
check(near(NavigationEngine(route: simpleRoute(), estimatedSpeed: 10).expectedTime(), 10), "expectedTime")

// dead reckoning + fallback
do {
    let e = NavigationEngine(route: simpleRoute(), estimatedSpeed: 10)
    check(e.tick(now: 5, isStationary: false, isMoving: true) == nil, "tick 50m no event")
    check(near(e.accumulatedDistance, 50), "accumulated 50")
    let ev = e.tick(now: 10, isStationary: false, isMoving: true)
    check(ev?.kind == .fallbackPrompt && ev?.milestone.id == "a", "fallback at A")
}

// smoothing slower / faster
do {
    let e = NavigationEngine(route: simpleRoute(), estimatedSpeed: 10)
    e.tick(now: 10, isStationary: false, isMoving: true)
    check(near(e.confirmArrival(now: 20), 5), "V_true slower = 5")
    check(near(e.estimatedSpeed, 8.5), "smoothed 8.5")
    check(e.currentIndex == 2, "advanced to 2")
}
do {
    let e = NavigationEngine(route: simpleRoute(), estimatedSpeed: 10)
    e.tick(now: 10, isStationary: false, isMoving: true)
    check(near(e.confirmArrival(now: 5), 20), "V_true faster = 20")
    check(near(e.estimatedSpeed, 13), "smoothed 13")
}

// hard gate
do {
    let e = NavigationEngine(route: simpleRoute(), estimatedSpeed: 10)
    for i in 1..<40 { e.tick(now: Double(i), isStationary: false, isMoving: true) }
    check(near(e.accumulatedDistance, 100), "gate caps at 100")
    check(e.currentIndex == 1, "held at node")
}

// no telemetry ⇒ no snap / no move / no corruption
do {
    let route = [Milestone(id: "o", type: "origin", distanceFromPrior: 0),
                 Milestone(id: "a", type: "stop_sign", distanceFromPrior: 30, name: "A"),
                 Milestone(id: "b", type: "destination", distanceFromPrior: 300)]
    let e = NavigationEngine(route: route, estimatedSpeed: 11)
    var t = 0.0, anyEvent = false
    for _ in 0..<400 { t += 0.05; if e.tick(now: t, isStationary: false, isMoving: false) != nil { anyEvent = true } }
    check(!anyEvent && e.currentIndex == 1 && near(e.accumulatedDistance, 0) && near(e.estimatedSpeed, 11),
          "no telemetry inert")
}

// short leg no insta-snap, then snaps after min leg time
do {
    let route = [Milestone(id: "o", type: "origin", distanceFromPrior: 0),
                 Milestone(id: "a", type: "stop_sign", distanceFromPrior: 30, name: "A"),
                 Milestone(id: "b", type: "destination", distanceFromPrior: 300)]
    let e = NavigationEngine(route: route, estimatedSpeed: 11)
    check(e.tick(now: 1, isStationary: true, isMoving: false) == nil, "no insta-snap")
    let ev = e.tick(now: 4, isStationary: true, isMoving: false)
    check(ev?.kind == .autoSnap && e.estimatedSpeed <= 45, "snap after min leg, speed sane")
}

// turn geometry
check(Turn.classify(Turn.turnAngle(prev: (0, 0), node: (0.001, 0), next: (0.001, 0.001))) == "right", "right turn")
check(Turn.classify(Turn.turnAngle(prev: (0, 0), node: (0.001, 0), next: (0.001, -0.001))) == "left", "left turn")
check(Turn.classify(Turn.turnAngle(prev: (0, 0), node: (0.001, 0), next: (0.002, 0.00001))) == "straight", "straight")

// calibration offset recovery + wraparound
do {
    let cal = HeadingCalibration(alpha: 0.1, minSamples: 20)
    for _ in 0..<60 { cal.add(compassDeg: Turn.wrap360(30 + 110), legBearingDeg: 30) }
    check(cal.calibrated && abs(Turn.angleDiff(cal.offset, 110)) < 3, "offset recovered ≈110")
    check(abs(Turn.angleDiff(cal.trueHeading(compassDeg: 230), 120)) < 3, "true heading 120")
}
do {
    let cal = HeadingCalibration(alpha: 0.1, minSamples: 20)
    for _ in 0..<60 { cal.add(compassDeg: 10, legBearingDeg: 350) }
    check(cal.calibrated && abs(Turn.angleDiff(cal.offset, 20)) < 3, "offset wraps north ≈20")
}

// tilt compass tracks 90° rotation
do {
    let g = (0.0, 0.0, 9.8)
    let d = abs(Turn.angleDiff(Fusion.tiltCompensatedHeading(accel: g, mag: (0, 20, -40)),
                               Fusion.tiltCompensatedHeading(accel: g, mag: (20, 0, -40))))
    check(d > 80 && d < 100, "compass tracks 90°")
}

// routing: A* across a 3x3 grid + milestone/turn conversion
do {
    // grid of nodes ~100 m apart (deg ≈ 0.0009). Corners n00..n22.
    let g = RoadGraph()
    let step = 0.0009
    for r in 0..<3 { for c in 0..<3 {
        g.addNode("n\(r)\(c)", lat: Double(r) * step, lon: Double(c) * step)
    }}
    for r in 0..<3 { for c in 0..<3 {
        if c < 2 { g.addEdge("n\(r)\(c)", "n\(r)\(c+1)", name: "row\(r)") }
        if r < 2 { g.addEdge("n\(r)\(c)", "n\(r+1)\(c)", name: "col\(c)") }
    }}
    let start = g.nearestNode(lat: 0, lon: 0)!
    let dest = g.nearestNode(lat: 2 * step, lon: 2 * step)!
    check(start == "n00" && dest == "n22", "nearest-node snap")
    let path = g.shortestPath(from: start, to: dest)
    check(path != nil && path!.first == "n00" && path!.last == "n22", "A* path ends correct")
    let route = g.buildRoute(path: path!)
    check(route.milestones.first?.type == "origin", "route starts at origin")
    check(route.milestones.last?.type == "destination", "route ends at destination")
    check(route.totalDistanceM > 350 && route.totalDistanceM < 450, "route length ≈ 4 legs")
    // grid edge nodes are degree-3 intersections (kept); corners are degree-2
    // (collapsed) — so the route keeps real intersections but not every node.
    check(route.milestones.count >= 3 && route.milestones.count <= 5, "keeps intersections, drops bends")
}

// turn detected at a REAL intersection (degree ≥ 3)
do {
    let g = RoadGraph()
    g.addNode("A", lat: 0, lon: 0)
    g.addNode("B", lat: 0, lon: 0.0018)        // east of A — the intersection
    g.addNode("C", lat: 0, lon: 0.0036)        // further east (makes B degree 3)
    g.addNode("D", lat: 0.0018, lon: 0.0018)   // north of B
    g.addEdge("A", "B", name: "Main St"); g.addEdge("B", "C", name: "Main St")
    g.addEdge("B", "D", name: "Oak Ave")
    let route = g.buildRoute(path: g.shortestPath(from: "A", to: "D")!)  // A→B→D, left at B
    check(route.nodes.contains { abs($0.turnAngle) > 60 }, "turn detected at real intersection")
    check(route.milestones.contains { $0.name == "Oak Ave" || $0.name == "Main St" }, "street name on leg")
}

// Overpass JSON → graph → route
do {
    let json = """
    {"elements":[
      {"type":"node","id":1,"lat":0.0,"lon":0.0},
      {"type":"node","id":2,"lat":0.0009,"lon":0.0},
      {"type":"node","id":3,"lat":0.0009,"lon":0.0009},
      {"type":"way","id":100,"nodes":[1,2,3],
       "tags":{"highway":"residential","name":"Main St","maxspeed":"30 mph"}}
    ]}
    """.data(using: .utf8)!
    let g = try! Overpass.buildGraph(from: json)
    check(g.nodes.count == 3, "overpass parsed 3 nodes")
    let path = g.shortestPath(from: "1", to: "3")
    check(path == ["1", "2", "3"], "overpass graph routes")
    let route = g.buildRoute(path: path!)
    check(route.milestones.count == 2, "straight road → origin+dest (geometry node collapsed)")
    // 30 mph ≈ 13.4 m/s
    check(abs((route.milestones.last?.targetSpeedLimit ?? 0) - 13.4) < 0.3, "maxspeed parsed")
}

// node types from Overpass + save/restore round-trip
do {
    let json = """
    {"elements":[
      {"type":"node","id":1,"lat":0.0,"lon":0.0},
      {"type":"node","id":2,"lat":0.0009,"lon":0.0,"tags":{"highway":"stop"}},
      {"type":"node","id":3,"lat":0.0018,"lon":0.0},
      {"type":"way","id":100,"nodes":[1,2,3],"tags":{"highway":"residential","name":"Oak St"}}
    ]}
    """.data(using: .utf8)!
    let g = try! Overpass.buildGraph(from: json)
    check(g.nodes["2"]?.type == "stop_sign", "node 2 parsed as stop sign")
    // save → restore → still routes + keeps the stop sign type
    let snap = g.snapshot()
    let data = try! JSONEncoder().encode(snap)
    let g2 = RoadGraph.restore(try! JSONDecoder().decode(RoadGraph.Snapshot.self, from: data))
    let path = g2.shortestPath(from: "1", to: "3")!
    let route = g2.buildRoute(path: path)
    check(route.milestones.contains { $0.type == "stop_sign" && $0.name == "Oak St" },
          "restored graph: stop sign on Oak St")
}

// gait model: learns stride from one leg, predicts live speed from cadence
do {
    let g = GaitModel()
    check(g.predict(cadence: 1.8) == nil, "gait untrained → nil")
    g.observe(cadence: 1.8, speed: 1.35)          // ~0.75 m stride
    check(g.trained, "gait trained after one leg")
    check(near(g.predict(cadence: 1.8) ?? 0, 1.35, 1e-9), "predicts the trained point")
    check(near(g.predict(cadence: 0.9) ?? 0, 0.675, 1e-9), "slower cadence → ~half speed")
    check((g.predict(cadence: 0) ?? -1) == 0, "no steps → speed 0 (dot holds)")
    check(abs(g.strideLength - 0.75) < 1e-9, "stride length ≈ 0.75 m")
}
do {
    let g = GaitModel()                            // two points → fitted line
    g.observe(cadence: 1.0, speed: 1.0)
    g.observe(cadence: 2.0, speed: 2.2)
    let p = g.predict(cadence: 1.5) ?? 0           // line: slope 1.2, intercept -0.2 → 1.6
    check(near(p, 1.6, 1e-6), "regression predicts midpoint")
    g.observe(cadence: 5.0, speed: 99)             // out of human range → rejected
    check(g.samples.count == 2, "implausible sample rejected")
}

// calibration analyzer: steady walk over leg-1 IS predictive; noise is NOT
do {
    // 100 m leg walked at 1.8 steps/s for 74 s ⇒ ~133 steps, 0.75 m stride.
    let a = CalibrationAnalyzer()
    for i in 0...740 {                              // 0.1 s ticks
        let t = Double(i) * 0.1
        a.record(time: t, cumulativeSteps: Int(1.8 * t))   // perfectly linear accrual
    }
    let r = a.analyze(distanceM: 100)
    check(r.predictive, "steady walk is predictive")
    check(r.predictability > 0.98, "steady gait → R² ≈ 1")
    check(abs(r.groundTruthSpeed - 100.0/74.0) < 0.1, "ground-truth speed ≈ 1.35 m/s")
    check(r.strideLength > 0.7 && r.strideLength < 0.8, "stride ≈ 0.75 m (100m/133 steps)")
}
do {
    // no real steps (in a car / phone still): zero/erratic → not predictive
    let a = CalibrationAnalyzer()
    for i in 0...200 { a.record(time: Double(i) * 0.1, cumulativeSteps: 0) }
    let r = a.analyze(distanceM: 400)
    check(!r.predictive, "no steps → not predictive (won't fake movement)")
}

// ── Wilderness Terrain Contour Navigation (WTCN) ─────────────────────────────

// DTW: identical → 0, time-warped → ~0, different shape → large; variance
do {
    let a = [0, 1, 2, 3, 4.0]
    let bWarp = [0, 0, 1, 2, 3, 4, 4.0]       // same shape, stretched in time
    let cDiff = [0, 5, 0, 5, 0.0]
    check(DTW.distance(a, a) == 0, "DTW identical = 0")
    check(DTW.distance(a, bWarp) < 1e-9, "DTW warp-invariant")
    check(DTW.distance(a, cDiff) > 0.3, "DTW different shape large")
    check(near(DTW.variance([3, 3, 3]), 0), "variance flat = 0")
    check(DTW.variance([0, 10]) > 0, "variance varied > 0")
}

// DEM: bilinear interpolation + relative profile along a heading
do {
    let d = GridDEM(cols: 2, rows: 2, cellSize: 10, heights: [0, 10, 20, 30])
    check(d.elevation(x: 0, y: 0) == 0 && d.elevation(x: 10, y: 0) == 10, "DEM corners")
    check(near(d.elevation(x: 5, y: 0)!, 5), "DEM bilinear edge")
    check(near(d.elevation(x: 5, y: 5)!, 15), "DEM bilinear center")
    check(d.elevation(x: -1, y: 0) == nil, "DEM off-grid = nil")

    let ramp = GridDEM(cols: 11, rows: 2, cellSize: 1, heights: (0..<22).map { Double($0 % 11) })
    let p = ramp.profile(from: GeoPoint(x: 0, y: 0), headingDeg: 90, length: 10, step: 1)  // east ⇒ +1/m
    check(p.count == 11 && near(p[0], 0) && near(p[10], 10), "relative profile climbs the ramp")
}

// Particle scatter stays inside the disc; resample preserves the count
do {
    var rng = SeededRNG(seed: 1)
    let ps = ParticleFilter.scatter(center: GeoPoint(x: 0, y: 0), radiusM: 100, count: 500, using: &rng)
    check(ps.count == 500, "scatter count")
    check(ps.allSatisfy { $0.point.distance(to: GeoPoint(x: 0, y: 0)) <= 100.001 }, "scatter in disc")
}

// Synthetic terrain: tilt + two Gaussian hills (a distinctive landscape).
func hill(_ x: Double, _ y: Double, _ cx: Double, _ cy: Double, _ amp: Double, _ s: Double) -> Double {
    amp * exp(-(((x - cx) * (x - cx) + (y - cy) * (y - cy)) / (2 * s * s)))
}
let cell = 30.0, dim = 60
var heights = [Double](repeating: 0, count: dim * dim)
for r in 0..<dim { for c in 0..<dim {
    let x = Double(c) * cell, y = Double(r) * cell
    heights[r * dim + c] = 0.005 * x
        + hill(x, y, 600, 1200, 140, 120) + hill(x, y, 1300, 500, 110, 140)
        + hill(x, y, 950, 800, 80, 90)
}}
let terrain = GridDEM(cols: dim, rows: dim, cellSize: cell, heights: heights)

// Flatland trap: a flat walk yields no signature ⇒ engine reports flatline
do {
    let eng = RecoveryEngine(dem: terrain)
    eng.begin(center: GeoPoint(x: 900, y: 900), radiusM: 600, count: 500)
    check(eng.step(barometricProfile: [0, 0.1, 0, 0.1, 0], headingDeg: 0) == .flatline,
          "flat walk ⇒ flatline")
}

// Full "I'm Lost" recovery: scatter → two orthogonal walks → converges on truth
do {
    // Truth is OFFSET from the scatter center, so localizing is a real result.
    let truth = GeoPoint(x: 1150, y: 700)
    let obsE = terrain.profile(from: truth, headingDeg: 90, length: 600, step: 30)   // walk east
    let obsN = terrain.profile(from: truth, headingDeg: 0,  length: 600, step: 30)   // walk north
    var cfg = RecoveryEngine.Config(); cfg.matchSigma = 5; cfg.jitterM = 10
    let eng = RecoveryEngine(dem: terrain, seed: 42, config: cfg)
    eng.begin(center: GeoPoint(x: 900, y: 900), radiusM: 600, count: 4000)
    var located = false
    for _ in 0..<8 {
        _ = eng.step(barometricProfile: obsE, headingDeg: 90)
        if case .located = eng.step(barometricProfile: obsN, headingDeg: 0) { located = true }
    }
    let d = eng.pf.estimate.distance(to: truth)
    check(d < 150, "recovery localizes within 150 m of truth (got \(Int(d)) m)")
    check(located, "recovery reaches a location lock")
}

// DEM tiles: XYZ math, Terrarium decode, raster sampling round-trip
do {
    // tile math: world halves at z=1
    check(TileMath.tileX(lon: -179.9, z: 1) == 0 && TileMath.tileX(lon: 0.1, z: 1) == 1, "tileX halves")
    check(TileMath.tileY(lat: 80, z: 1) == 0 && TileMath.tileY(lat: -1, z: 1) == 1, "tileY halves")
    // a tiny bbox falls in a single tile; a wider one spans several
    check(TileMath.tiles(south: 34.99, west: -82.01, north: 35.0, east: -82.0, z: 12).count <= 2,
          "tiny bbox = 1-2 tiles")
    check(TileMath.tiles(south: 34.8, west: -82.2, north: 35.0, east: -82.0, z: 12).count >= 4,
          "wider bbox spans tiles")

    // Terrarium decode anchors: 128,0,0 → 0 m; +1 R → +256 m; B is the 1/256 m bit
    check(near(Terrarium.elevation(r: 128, g: 0, b: 0), 0), "terrarium zero point")
    check(near(Terrarium.elevation(r: 129, g: 0, b: 0), 256), "terrarium +R = +256 m")
    check(near(Terrarium.elevation(r: 128, g: 10, b: 128), 10.5), "terrarium G+B fraction")

    // raster sampling: origin lands inside, far point is off-map (nil)
    let z = 12, oLat = 35.0, oLon = -82.0
    let gpx = TileMath.globalPixelX(lon: oLon, z: z), gpy = TileMath.globalPixelY(lat: oLat, z: z)
    let px0 = Int(gpx) - 3, py0 = Int(gpy) - 3, w = 8, h = 8
    let dem = TerrariumDEM(z: z, px0: px0, py0: py0, width: w, height: h,
                           elev: (0..<(w * h)).map { Int16($0) }, originLat: oLat, originLon: oLon)
    check(dem.elevation(x: 0, y: 0) != nil, "origin samples inside raster")
    check(dem.elevation(x: 5_000_000, y: 0) == nil, "far point off raster → nil")
    // meters ⇆ lat/lon inverse
    let back = dem.meters(lat: dem.latLon(x: 120, y: -75).lat, lon: dem.latLon(x: 120, y: -75).lon)
    check(near(back.x, 120, 1e-3) && near(back.y, -75, 1e-3), "meters↔latlon inverse")
}

// TerrainSiphon: time-sampled altitude + step-odometry distance → distance profile
do {
    // climb at 0.5 m per meter walked; samples every 10 m to 300 m
    let dist = Swift.stride(from: 0, through: 300, by: 10).map { Double($0) }
    let alt = dist.map { 0.5 * $0 }
    let prof = TerrainSiphon.distanceProfile(altitudes: alt, distances: dist, step: 30)
    check(prof.count == 11, "profile has 11 bins over 300 m @30 m")
    check(near(prof[0], 0) && near(prof[1], 15) && near(prof[10], 150, 1e-6), "relative climb 0,15,…,150")
    // flat walk → all zeros
    let flat = TerrainSiphon.distanceProfile(altitudes: Array(repeating: 5, count: 20),
                                             distances: dist, step: 30)
    check(flat.allSatisfy { near($0, 0) }, "flat walk → zero profile")
    // too short → empty
    check(TerrainSiphon.distanceProfile(altitudes: [0, 1], distances: [0, 5], step: 30).isEmpty,
          "sub-bin walk → empty")
}

// Horizon / interrogation: a ridge wall splits two candidates on either side
do {
    // tall narrow N-S wall at x≈1000; flat elsewhere
    let cols = 80, rows = 20, cs = 30.0
    var h = [Double](repeating: 0, count: cols * rows)
    for r in 0..<rows { for c in 0..<cols {
        let x = Double(c) * cs
        h[r * cols + c] = 250 * exp(-((x - 1000) * (x - 1000)) / (2 * 60 * 60))
    }}
    let ridge = GridDEM(cols: cols, rows: rows, cellSize: cs, heights: h)
    let east = GeoPoint(x: 1400, y: 300)   // east of the wall: looking West hits the ridge
    let west = GeoPoint(x: 600, y: 300)    // west of the wall: looking West is open

    check(Horizon.ridgeBlocked(dem: ridge, from: east, headingDeg: 270, rangeM: 800, step: 40),
          "east candidate: ridge blocks the West horizon")
    check(!Horizon.ridgeBlocked(dem: ridge, from: west, headingDeg: 270, rangeM: 800, step: 40),
          "west candidate: West horizon is open")

    let q = Interrogation.bestQuestion(dem: ridge, candidates: [east, west], rangeM: 800, step: 40)
    check(q != nil, "found a discriminating question")
    if let q {
        let a = Horizon.ridgeBlocked(dem: ridge, from: east, headingDeg: q.headingDeg, rangeM: 800, step: 40)
        let b = Horizon.ridgeBlocked(dem: ridge, from: west, headingDeg: q.headingDeg, rangeM: 800, step: 40)
        check(a != b, "the chosen bearing separates the two candidates")
    }
    check(Interrogation.name(forHeading: 271) == "West" && Interrogation.name(forHeading: 0) == "North",
          "compass naming")
}

// PathSiphon: bins synced (distance, altitude, heading) samples
do {
    let d = Swift.stride(from: 0, through: 200, by: 10).map { Double($0) }
    let alt = d.map { $0 < 100 ? 0.1 * $0 : 10.0 }                 // climb then plateau
    let hdg = d.map { $0 < 100 ? 90.0 : 0.0 }                      // east, then turn north
    let (prof, heads) = PathSiphon.build(distances: d, altitudes: alt, headings: hdg, step: 30)
    check(prof.count == heads.count && prof.count == 7, "path binned to 7")
    check(near(prof[0], 0) && prof.last! > 9, "relative climb captured")
    check(heads.first == 90 && heads.last == 0, "heading turn captured")
}

// Full L-shaped recovery: straight climb + turn + descent fuses into one fingerprint
do {
    // distinctive, NON-periodic terrain (irregular peaks) → unique L-path fingerprint
    let peaks: [(Double, Double, Double, Double)] = [
        (300, 400, 80, 90), (1200, 800, 130, 150), (700, 1300, 70, 80),
        (1500, 300, 100, 110), (950, 950, 60, 65), (450, 1150, 75, 95)]
    var rh = [Double](repeating: 0, count: dim * dim)
    for r in 0..<dim { for c in 0..<dim {
        let x = Double(c) * cell, y = Double(r) * cell
        rh[r * dim + c] = 0.01 * x + peaks.reduce(0) { $0 + hill(x, y, $1.0, $1.1, $1.2, $1.3) }
    }}
    let terrain = GridDEM(cols: dim, rows: dim, cellSize: cell, heights: rh)
    let truth = GeoPoint(x: 700, y: 700)
    // simulate the walk FROM truth: 300 m east, then 300 m north, sampling the DEM
    var dist: [Double] = [], alt: [Double] = [], head: [Double] = []
    var cur = truth, traveled = 0.0
    for leg in [(90.0, 300.0), (0.0, 300.0)] {
        let rad = leg.0 * .pi / 180, dx = sin(rad) * 10, dy = cos(rad) * 10
        for _ in 0..<Int(leg.1 / 10) {
            dist.append(traveled); alt.append(terrain.elevation(x: cur.x, y: cur.y) ?? 0); head.append(leg.0)
            cur = GeoPoint(x: cur.x + dx, y: cur.y + dy); traveled += 10
        }
    }
    let (prof, heads) = PathSiphon.build(distances: dist, altitudes: alt, headings: head, step: 30)
    var cfg = RecoveryEngine.Config(); cfg.matchSigma = 4; cfg.jitterM = 8
    let eng = RecoveryEngine(dem: terrain, seed: 7, config: cfg)
    eng.begin(center: GeoPoint(x: 900, y: 900), radiusM: 600, count: 4000)
    var located = false
    for _ in 0..<12 {
        if case .located = eng.stepPath(observedProfile: prof, headings: heads) { located = true }
    }
    check(eng.pf.estimate.distance(to: truth) < 140, "L-path recovery localizes (got \(Int(eng.pf.estimate.distance(to: truth))) m)")
    check(located, "L-path recovery reaches a lock")
}

// MVT geometry decode: the spec's canonical LineString + Polygon examples
do {
    // LineString MoveTo(2,2) LineTo(2,10) LineTo(10,10)
    let line = MVT.decodeGeometry([9, 4, 4, 18, 0, 16, 16, 0])
    check(line.count == 1 && line[0].count == 3, "MVT line: one part, 3 pts")
    check(line[0][0].x == 2 && line[0][0].y == 2 && line[0][2].x == 10 && line[0][2].y == 10, "MVT line coords")
    // Polygon MoveTo(3,6) LineTo(8,12) LineTo(20,34) ClosePath
    let poly = MVT.decodeGeometry([9, 6, 12, 18, 10, 12, 24, 44, 15])
    check(poly.count == 1 && poly[0].count == 3, "MVT polygon ring")
    check(poly[0][0].x == 3 && poly[0][0].y == 6 && poly[0][2].x == 20 && poly[0][2].y == 34, "MVT polygon coords")
    // negative delta (zigzag of odd numbers)
    let back = MVT.decodeGeometry([9, 50, 34, 10, 3, 9])   // MoveTo(25,17) LineTo(-2,-5)
    check(back[0][0].x == 25 && back[0][0].y == 17, "MVT zigzag positive")
    check(back[0][1].x == 23, "MVT zigzag negative delta")

    // tile-local → lon/lat: NW corner of tile 12/1115/1638 ≈ (-82.00, 33.87)
    let nw = TileMath.tileToLonLat(z: 12, x: 1115, y: 1638, tx: 0, ty: 0, extent: 4096)
    check(abs(nw.lon - (-82.0)) < 0.01 && abs(nw.lat - 33.87) < 0.02, "MVT tile NW corner geo")
}

// Real OpenFreeMap tile if present (ad-hoc end-to-end validation)
if let data = FileManager.default.contents(atPath: "/tmp/feat.pbf") {
    let tile = try! MVT.decode(data)
    let names = Set(tile.layers.map(\.name))
    print("  [MVT real tile] " + tile.layers.map { "\($0.name):\($0.features.count)" }.joined(separator: " "))
    check(!tile.layers.isEmpty, "real tile decodes to layers")
    check(names.contains("water") || names.contains("waterway") || names.contains("landcover")
          || names.contains("boundary"), "real tile exposes feature layers")
}

// FeatureField relational queries: "stream on the right?", "in a lake?", "nearest peak"
do {
    let stream = MapFeature(kind: .waterway, isArea: false,
                            points: [GeoPoint(x: 50, y: -100), GeoPoint(x: 50, y: 100)])   // line at x=50 (east)
    let lake = MapFeature(kind: .water, isArea: true,
                          points: [GeoPoint(x: -20, y: -20), GeoPoint(x: 20, y: -20),
                                   GeoPoint(x: 20, y: 20), GeoPoint(x: -20, y: 20)])
    let peak = MapFeature(kind: .peak, isArea: false, points: [GeoPoint(x: 0, y: 300)], name: "Test Peak")
    let ff = FeatureField(originLat: 35, originLon: -82, features: [stream, lake, peak])
    let p = GeoPoint(x: 0, y: 0)

    let nw = ff.nearest([.waterway], to: p)!
    check(near(nw.distance, 50, 1e-6), "nearest stream 50 m")
    check(abs(Turn.angleDiff(nw.bearing, 90)) < 1, "stream bearing east ≈ 90°")
    check(ff.onSide([.waterway], from: p, heading: 0, within: 100, side: .right), "stream on the RIGHT facing north")
    check(!ff.onSide([.waterway], from: p, heading: 0, within: 100, side: .left), "stream not on the left")
    check(!ff.onSide([.waterway], from: p, heading: 0, within: 30, side: .right), "out of range ⇒ no")
    check(ff.containing([.water], point: GeoPoint(x: 0, y: 0)) != nil, "origin is inside the lake")
    check(ff.containing([.water], point: GeoPoint(x: 100, y: 100)) == nil, "far point not in the lake")
    let np = ff.nearest([.peak], to: p)!
    check(np.feature.name == "Test Peak" && near(np.distance, 300, 1e-6), "nearest peak named + 300 m")
}

// Build a FeatureField from the real OpenFreeMap tile (ad-hoc end-to-end)
if let data = FileManager.default.contents(atPath: "/tmp/feat.pbf") {
    let tile = try! MVT.decode(data)
    let ff = FeatureField.fromMVT(tiles: [(tile, 12, 1115, 1638)], originLat: 33.83, originLon: -81.95)
    let water = ff.features.filter { $0.kind == .water }.count
    print("  [FeatureField real] total=\(ff.features.count) water=\(water)")
    check(ff.features.count > 0 && water > 0, "feature field built from real tile (has water)")
}

// Lake masking: rejection-scatter keeps ghosts out of a big central lake
do {
    let lake = MapFeature(kind: .water, isArea: true,
                          points: [GeoPoint(x: -300, y: -300), GeoPoint(x: 300, y: -300),
                                   GeoPoint(x: 300, y: 300), GeoPoint(x: -300, y: 300)])
    let ff = FeatureField(originLat: 0, originLon: 0, features: [lake])
    var rng = SeededRNG(seed: 3)
    let ps = ParticleFilter.scatter(center: GeoPoint(x: 0, y: 0), radiusM: 800, count: 3000, using: &rng,
                                    reject: { ff.containing([.water], point: $0) != nil })
    let inLake = ps.filter { ff.containing([.water], point: $0.point) != nil }.count
    check(inLake == 0, "no ghosts scattered inside the lake")
    check(ps.count == 3000, "still 3000 ghosts (relocated, not dropped)")
}

// Feature interrogation: a stream east splits "stream on your right?" by candidate
do {
    let stream = MapFeature(kind: .waterway, isArea: false,
                            points: [GeoPoint(x: 1050, y: 900), GeoPoint(x: 1050, y: 1100)])  // near candidate A
    let ff = FeatureField(originLat: 0, originLon: 0, features: [stream])
    let a = GeoPoint(x: 1000, y: 1000)   // stream ~50 m east → on the right when facing north
    let b = GeoPoint(x: 200, y: 200)     // far from any stream
    let q = FeatureInterrogation.bestQuestion(field: ff, candidates: [a, b], heading: 0)
    check(q != nil, "found a discriminating feature question")
    if let q {
        check(q.holds(at: a, field: ff) != q.holds(at: b, field: ff), "feature question separates candidates")
    }
}

// Binary codecs: DEM + FeatureField round-trip, compact
do {
    let dem = TerrariumDEM(z: 12, px0: 1000, py0: 2000, width: 4, height: 3,
                           elev: [-5, 0, 100, 32000, -32000, 1, 2, 3, 4, 5, 6, 7],
                           originLat: 35.1, originLon: -82.2)
    let data = dem.encodedBinary()
    let back = TerrariumDEM.decodeBinary(data)!
    check(back.z == 12 && back.px0 == 1000 && back.width == 4 && back.height == 3, "DEM bin header")
    check(back.elev == dem.elev, "DEM bin elev exact")
    check(near(back.originLat, 35.1) && near(back.originLon, -82.2), "DEM bin origin")
    check(data.count == 61, "DEM bin compact (61 bytes for 12 samples)")

    let feats = [
        MapFeature(kind: .waterway, isArea: false, points: [GeoPoint(x: 1, y: 2), GeoPoint(x: 3, y: 4)]),
        MapFeature(kind: .water, isArea: true,
                   points: [GeoPoint(x: -10, y: -10), GeoPoint(x: 10, y: -10), GeoPoint(x: 0, y: 20)], name: "Lake X"),
        MapFeature(kind: .peak, isArea: false, points: [GeoPoint(x: 100, y: 200)], name: "Pk"),
    ]
    let ff = FeatureField(originLat: 34, originLon: -81, features: feats)
    let fb = FeatureField.decodeBinary(ff.encodedBinary())!
    check(fb.features.count == 3, "feat bin count")
    check(fb.features[1].kind == .water && fb.features[1].isArea && fb.features[1].name == "Lake X", "feat bin fields")
    check(abs(fb.features[0].points[1].x - 3) < 0.01 && abs(fb.features[2].points[0].y - 200) < 0.01, "feat bin points")
    check(fb.features[0].name == nil, "feat bin nil name preserved")
    check(near(fb.originLat, 34) && near(fb.originLon, -81), "feat bin origin")
}

// CloudQuiz: pick the most balanced (≈50/50) yes/no question over the cloud
do {
    check(CloudQuiz.bestSplitIndex(yesWeights: [0.05, 0.48, 0.9], total: 1.0) == 1, "picks the ~50/50 split")
    check(CloudQuiz.bestSplitIndex(yesWeights: [0.02, 0.97], total: 1.0) == nil, "no balanced split → nil")
    check(CloudQuiz.bestSplitIndex(yesWeights: [0.3, 0.52, 0.42], total: 1.0) == 1, "closest to half wins")
}

// ONE distinctive walk should strongly concentrate the cloud with a tight sigma
do {
    let peaks: [(Double, Double, Double, Double)] = [
        (300, 400, 80, 90), (1200, 800, 130, 150), (700, 1300, 70, 80),
        (1500, 300, 100, 110), (950, 950, 60, 65), (450, 1150, 75, 95)]
    var rh = [Double](repeating: 0, count: dim * dim)
    for r in 0..<dim { for c in 0..<dim {
        let x = Double(c) * cell, y = Double(r) * cell
        rh[r * dim + c] = 0.01 * x + peaks.reduce(0) { $0 + hill(x, y, $1.0, $1.1, $1.2, $1.3) }
    }}
    let terr = GridDEM(cols: dim, rows: dim, cellSize: cell, heights: rh)
    let truth = GeoPoint(x: 700, y: 700)
    var dist: [Double] = [], alt: [Double] = [], head: [Double] = []
    var cur = truth, traveled = 0.0
    for leg in [(90.0, 300.0), (0.0, 300.0)] {
        let rad = leg.0 * .pi / 180, dx = sin(rad) * 10, dy = cos(rad) * 10
        for _ in 0..<Int(leg.1 / 10) {
            dist.append(traveled); alt.append(terr.elevation(x: cur.x, y: cur.y) ?? 0); head.append(leg.0)
            cur = GeoPoint(x: cur.x + dx, y: cur.y + dy); traveled += 10
        }
    }
    let (prof, heads) = PathSiphon.build(distances: dist, altitudes: alt, headings: head, step: 30)
    var cfg = RecoveryEngine.Config(); cfg.matchSigma = 3; cfg.jitterM = 12
    let eng = RecoveryEngine(dem: terr, seed: 11, config: cfg)
    eng.begin(center: GeoPoint(x: 900, y: 900), radiusM: 600, count: 4000)
    _ = eng.stepPath(observedProfile: prof, headings: heads)          // exactly ONE walk
    let conc = eng.pf.weightConcentration(radiusM: 250, around: truth)
    check(conc > 0.35, "one distinctive walk concentrates >35% near truth (got \(Int(conc * 100))%, uniform≈17%)")
}

// WMM2025 declination vs NOAA's official test values (lat, lon, alt km, year → D°)
do {
    func D(_ lat: Double, _ lon: Double, _ alt: Double, _ yr: Double) -> Double {
        GeoMagnetism.declination(latDeg: lat, lonDeg: lon, year: yr, altKm: alt)
    }
    check(abs(D(0, 21, 18, 2025.0) - 1.29) < 0.1, "WMM eq Africa = 1.29° (got \(String(format: "%.2f", D(0, 21, 18, 2025.0))))")
    check(abs(D(43, 93, 65, 2025.0) - 0.50) < 0.1, "WMM Asia = 0.50°")
    check(abs(D(-33, 109, 51, 2025.0) - (-5.49)) < 0.1, "WMM Indian Ocean = -5.49°")
    check(abs(D(26, 81, 63, 2025.5) - 0.51) < 0.1, "WMM India 2025.5 (secular var) = 0.51°")
    check(abs(D(-59, -8, 39, 2025.0) - (-15.75)) < 0.1, "WMM S.Atlantic = -15.75°")
    // Clemson, SC sanity — should be a few degrees west (negative)
    let clemson = D(34.68, -82.84, 0, 2026.0)
    print("  [WMM] Clemson SC 2026 declination = \(String(format: "%.2f", clemson))°")
    check(clemson < -3 && clemson > -10, "Clemson declination is a few degrees west")
}

// candidateCount: two heavy clusters + a low-weight tail → 2 real candidates
do {
    let d = GridDEM(cols: 2, rows: 2, cellSize: 10, heights: [0, 0, 0, 0])
    var ps: [Particle] = []
    for _ in 0..<10 { ps.append(Particle(x: 0, y: 0, weight: 0.045)) }       // cluster A (0.45)
    for _ in 0..<10 { ps.append(Particle(x: 1000, y: 0, weight: 0.045)) }    // cluster B (0.45)
    for i in 0..<100 { ps.append(Particle(x: 3000 + Double(i) * 100, y: 0, weight: 0.001)) } // tail (0.10)
    let pf = ParticleFilter(dem: d, particles: ps)
    check(pf.candidateCount(radiusM: 50, coverage: 0.8) == 2, "two significant candidate areas (tail ignored)")
    check(pf.candidateCount(radiusM: 50, coverage: 0.99) > 2, "high coverage includes the tail")
}

// Road-shape matching: a distinctive L-path replays onto roads only at the true start
do {
    let segs: [(GeoPoint, GeoPoint)] = [
        (GeoPoint(x: 0, y: 0), GeoPoint(x: 300, y: 0)),       // road east
        (GeoPoint(x: 300, y: 0), GeoPoint(x: 300, y: 300)),   // road north (the corner)
        (GeoPoint(x: 0, y: 1000), GeoPoint(x: 600, y: 1000)), // distractor: straight road only
    ]
    let ri = RoadIndex(segments: segs, cell: 60)
    check(ri.nearestDistance(to: GeoPoint(x: 150, y: 4)) < 6, "point on a road")
    check(ri.nearestDistance(to: GeoPoint(x: 150, y: 200)) > 100, "point off all roads")

    var headings: [Double] = []
    for _ in 0..<10 { headings.append(90) }   // 300 m east
    for _ in 0..<10 { headings.append(0) }    // then 300 m north (the L corner)
    let trueAdh = ri.pathAdherence(from: GeoPoint(x: 0, y: 0), headings: headings, step: 30, tolerance: 20)
    let wrongAdh = ri.pathAdherence(from: GeoPoint(x: 0, y: 1000), headings: headings, step: 30, tolerance: 20)
    check(trueAdh > 0.9, "L-path follows the roads from the true start (\(Int(trueAdh * 100))%)")
    check(wrongAdh < 0.65, "same L-path leaves the road from a straight-road start (\(Int(wrongAdh * 100))%)")

    // particle cull: ghosts on the L-corner survive; ghosts on the distractor die
    let dem = GridDEM(cols: 2, rows: 2, cellSize: 10, heights: [0, 0, 0, 0])
    let pf = ParticleFilter(dem: dem, particles: [
        Particle(x: 0, y: 0, weight: 0.5),          // true start
        Particle(x: 0, y: 1000, weight: 0.5),       // distractor
    ])
    pf.weightByRoadPath(ri, headings: headings, step: 30, tolerance: 20, sharpness: 6)
    check(pf.particles[0].weight > 0.9, "road match concentrates weight on the true start")

    // Phone rotated 40° in a pocket: the recorded shape is offset, but rotation
    // search recovers it and still fits the road at the true start.
    let offset = 40.0
    let recorded = headings.map { $0 + offset }
    let est = ri.estimateRotation(candidates: [GeoPoint(x: 0, y: 0), GeoPoint(x: 0, y: 1000)],
                                  headings: recorded, step: 30, tolerance: 20)
    let adhCorrected = ri.pathAdherence(from: GeoPoint(x: 0, y: 0), headings: recorded,
                                        step: 30, tolerance: 20, rotationDeg: est.rotation)
    check(adhCorrected > 0.9, "rotation search undoes the pocket offset (rot≈\(Int(est.rotation))°, fit \(Int(adhCorrected * 100))%)")

    // On-road scatter: every ghost starts on a road
    var rng2 = SeededRNG(seed: 9)
    let onRoadPts = ri.sampleOnRoad(count: 400, jitterM: 5, using: &rng2)
    check(onRoadPts.count == 400, "sampled 400 on-road points")
    check(onRoadPts.allSatisfy { ri.nearestDistance(to: $0) <= 8 }, "all on-road ghosts are on a road")
}

// Dense street grid (the Clemson failure): the OLD "near any road" metric
// saturated to ~1 everywhere; "along the road" must reject a diagonal that cuts
// across blocks while always staying near some street.
do {
    var segs: [(GeoPoint, GeoPoint)] = []
    let n = 8; let spacing = 100.0; let span = Double(n) * spacing
    for i in 0...n {
        let c = Double(i) * spacing
        segs.append((GeoPoint(x: 0, y: c), GeoPoint(x: span, y: c)))   // E-W streets
        segs.append((GeoPoint(x: c, y: 0), GeoPoint(x: c, y: span)))   // N-S streets
    }
    let grid = RoadIndex(segments: segs, cell: 60)
    let along = Array(repeating: 90.0, count: 12)   // walk EAST along a street
    let diag  = Array(repeating: 45.0, count: 12)   // walk NE diagonally across blocks
    let aAlong = grid.pathAdherence(from: GeoPoint(x: 0, y: 200), headings: along, step: 30, tolerance: 30)
    let aDiag  = grid.pathAdherence(from: GeoPoint(x: 0, y: 0),   headings: diag,  step: 30, tolerance: 30)
    check(aAlong > 0.8, "along-street walk follows the grid (\(Int(aAlong * 100))%)")
    check(aDiag < 0.4, "diagonal cross-grid walk does NOT count, though always near a road (\(Int(aDiag * 100))%)")
    check(aAlong > aDiag + 0.4, "directional adherence separates along-road from across-grid")
}

// CurveMatcher: road SHAPE eliminates non-matching places; ELEVATION breaks ties
// between two identically-shaped streets. Fuzzy (DTW + tolerant road fit).
do {
    // Terrain: a strong hill near the TRUE L; gentle tilt out where the decoy L is.
    let dim2 = 70, c2 = 30.0
    var h2 = [Double](repeating: 0, count: dim2 * dim2)
    for r in 0..<dim2 { for c in 0..<dim2 {
        let x = Double(c) * c2, y = Double(r) * c2
        h2[r * dim2 + c] = 0.008 * x + hill(x, y, 520, 380, 90, 110)   // hill the TRUE walk climbs
    }}
    let terr = GridDEM(cols: dim2, rows: dim2, cellSize: c2, heights: h2)
    func makeL(_ ox: Double, _ oy: Double) -> [(GeoPoint, GeoPoint)] {
        [(GeoPoint(x: ox, y: oy), GeoPoint(x: ox + 200, y: oy)),
         (GeoPoint(x: ox + 200, y: oy), GeoPoint(x: ox + 200, y: oy + 200)),
         (GeoPoint(x: ox + 200, y: oy + 200), GeoPoint(x: ox + 400, y: oy + 200))]
    }
    var segs = makeL(300, 300) + makeL(1400, 300)                   // true L + an identical decoy L
    segs.append((GeoPoint(x: 0, y: 1500), GeoPoint(x: 2000, y: 1500)))  // a straight decoy road
    let roads = RoadIndex(segments: segs, cell: 60)

    // walk the L from the TRUE start; the barometer = real terrain along it
    let truth = GeoPoint(x: 300, y: 300)
    var headings: [Double] = [], alt: [Double] = []
    var cur = truth
    for leg in [(90.0, 200.0), (0.0, 200.0), (90.0, 200.0)] {
        let rad = leg.0 * .pi / 180, dx = sin(rad) * 30, dy = cos(rad) * 30
        for _ in 0..<Int(leg.1 / 30) {
            headings.append(leg.0); alt.append(terr.elevation(x: cur.x, y: cur.y) ?? 0)
            cur = GeoPoint(x: cur.x + dx, y: cur.y + dy)
        }
    }
    let base = alt.first ?? 0
    let profile = alt.map { $0 - base }

    var rng = SeededRNG(seed: 7)
    let cands = roads.sampleOnRoad(count: 4000, jitterM: 6, using: &rng)
    let m = CurveMatcher(dem: terr, roads: roads, candidates: cands)
    m.scorePath(headings: headings, profile: profile)
    let lead = m.lead
    check(lead.distance(to: truth) < 90, "curve matcher locks the TRUE L, not the identical decoy (\(Int(lead.distance(to: truth))) m off)")
    let cl = m.clusters(radiusM: 120)
    let trueW = cl.filter { $0.center.distance(to: truth) < 160 }.reduce(0) { $0 + $1.weight }
    let decoyW = cl.filter { $0.center.distance(to: GeoPoint(x: 1400, y: 300)) < 160 }.reduce(0) { $0 + $1.weight }
    check(trueW > decoyW * 2, "elevation breaks the tie toward the real hill (true \(Int(trueW*100))% vs decoy \(Int(decoyW*100))%)")
}

// MARK: slope / aspect — downhill bearing on a tilted plane
do {
    // Plane that rises 1 m per m toward east (+x): downhill points west = 270°.
    let n = 11
    var h = [Double](repeating: 0, count: n * n)
    for r in 0..<n { for c in 0..<n { h[r * n + c] = Double(c) } }   // height = x index
    let plane = GridDEM(cols: n, rows: n, cellSize: 1, originX: -5, originY: -5, heights: h)
    let sa = plane.slopeAspect(at: GeoPoint(x: 0, y: 0), stepM: 1)!
    check(near(sa.downhillDeg, 270, 1.0), "downhill bearing points west on an east-rising slope (\(Int(sa.downhillDeg))°)")
    check(near(sa.slopeDeg, 45, 1.0), "slope of a 1:1 plane is ~45° (\(Int(sa.slopeDeg))°)")
    check(bearingDelta(10, 350) == 20, "bearingDelta wraps across north")
}

// MARK: solar position — sanity (noon high & south-ish; midnight below horizon)
do {
    // 2025-06-21T12:00:00Z = unix 1750507200 (near solar noon at lon 0).
    let noon = SolarPosition.at(latDeg: 40, lonDeg: 0, unixTime: 1_750_507_200)
    check(noon.elevationDeg > 60 && noon.elevationDeg < 75, "summer-noon sun is high at lat 40 (\(Int(noon.elevationDeg))°)")
    check(bearingDelta(noon.azimuthDeg, 180) < 20, "midday sun is roughly south (\(Int(noon.azimuthDeg))°)")
    let midnight = SolarPosition.at(latDeg: 40, lonDeg: 0, unixTime: 1_750_507_200 + 43_200)
    check(midnight.elevationDeg < 0, "sun is below the horizon at local midnight (\(Int(midnight.elevationDeg))°)")
}

// MARK: sun-on-ground — a ridge to the east shadows the valley at low eastern sun
do {
    let cols = 40, rows = 5, cs = 30.0
    var h = [Double](repeating: 0, count: cols * rows)
    for r in 0..<rows { for c in 0..<cols where c >= 30 { h[r * cols + c] = 400 } }  // tall wall to the east
    let valley = GridDEM(cols: cols, rows: rows, cellSize: cs, originX: 0, originY: 0, heights: h)
    let lowEastSun = SolarPosition.Sun(azimuthDeg: 90, elevationDeg: 10)   // low, due east
    let inValley = GeoPoint(x: 300, y: 60)   // west of the wall → blocked
    let onWall = GeoPoint(x: 1100, y: 60)    // atop the wall → lit
    check(valley.sunOnGround(at: inValley, sun: lowEastSun) == false, "low eastern sun is blocked by the ridge in the valley")
    check(valley.sunOnGround(at: onWall, sun: lowEastSun) == true, "the ridge top still sees the low eastern sun")
    let highSun = SolarPosition.Sun(azimuthDeg: 90, elevationDeg: 80)
    check(valley.sunOnGround(at: inValley, sun: highSun) == true, "the high midday sun clears the ridge everywhere")
}

// RouteMatcher: graph map-matching localizes a walk by snapping it onto the road
// network (heading + elevation), robust to per-step heading noise — the approach
// validated offline to ~28 m on a real field log.
do {
    let G = 9; let sp = 100.0                       // 9×9 grid, 100 m blocks
    func nid(_ i: Int, _ j: Int) -> Int { i * G + j }
    var nodes: [GeoPoint] = []
    for i in 0..<G { for j in 0..<G { nodes.append(GeoPoint(x: Double(i) * sp, y: Double(j) * sp)) } }
    var adjacency = [[Int]](repeating: [], count: G * G)
    for i in 0..<G { for j in 0..<G {
        if i + 1 < G { adjacency[nid(i, j)].append(nid(i + 1, j)); adjacency[nid(i + 1, j)].append(nid(i, j)) }
        if j + 1 < G { adjacency[nid(i, j)].append(nid(i, j + 1)); adjacency[nid(i, j + 1)].append(nid(i, j)) }
    }}
    // DEM: gentle tilt + a hill, so different places have different climb profiles.
    var heights = [Double](repeating: 0, count: G * G)
    for i in 0..<G { for j in 0..<G {
        let x = Double(i) * sp, y = Double(j) * sp
        heights[j * G + i] = 0.03 * x + 0.02 * y + 25 * exp(-((x - 300) * (x - 300) + (y - 700) * (y - 700)) / (2 * 180 * 180))
    }}
    let dem = GridDEM(cols: G, rows: G, cellSize: sp, heights: heights)

    // True walk: start (0,300), go EAST 400 m, then NORTH 200 m → end (400,500).
    let step = 15.0
    var headings: [Double] = [], cumElev: [Double] = []
    var cur = GeoPoint(x: 0, y: 300); let e0 = dem.elevation(x: cur.x, y: cur.y)!
    func leg(_ hdg: Double, _ dist: Double, _ k0: Int) {
        let n = Int(dist / step)
        for n2 in 0..<n {
            let noise = Double((k0 + n2) % 5 - 2) * 6     // deterministic ±12° heading noise
            headings.append(hdg + noise)
            let r = hdg * .pi / 180
            cur = GeoPoint(x: cur.x + sin(r) * step, y: cur.y + cos(r) * step)
            cumElev.append((dem.elevation(x: cur.x, y: cur.y) ?? e0) - e0)
        }
    }
    leg(90, 400, 0)     // east
    leg(0, 200, 99)     // north

    let rm = RouteMatcher(nodes: nodes, adjacency: adjacency, dem: dem)
    rm.matchWalk(stepM: step, headings: headings, cumElev: cumElev, seedSpacingM: 20)
    let truth = GeoPoint(x: 400, y: 500)
    let est = rm.estimate()!
    check(est.distance(to: truth) < 70, "route-matcher locks the walked route to the right place (\(Int(est.distance(to: truth))) m off, \(rm.walkerCount) survivors)")
    check(rm.concentration(radiusM: 120) > 0.25, "route-matcher concentrates onto the answer (conc \(Int(rm.concentration(radiusM: 120) * 100))%)")

    // Sequential pruning: the longer you walk, the more certain it gets.
    let rmShort = RouteMatcher(nodes: nodes, adjacency: adjacency, dem: dem)
    rmShort.matchWalk(stepM: step, headings: Array(headings.prefix(6)), cumElev: Array(cumElev.prefix(6)), seedSpacingM: 20)
    check(rmShort.concentration(radiusM: 120) < rm.concentration(radiusM: 120),
          "confidence grows as the walk lengthens (\(Int(rmShort.concentration(radiusM: 120) * 100))% after 90 m → \(Int(rm.concentration(radiusM: 120) * 100))% after 600 m)")
}

print("\nAnumaanCore self-test: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
