import Foundation
import AnumaanCore
import PNG

/// Real-area recovery simulator. Two entry points:
///   - `fromLL`/`toLL`: finds shortest road path between two points (default demo mode)
///   - `pathLL`:         uses the provided lat/lon array directly as the walk polyline
///                       (what the Python web app sends when the user draws their own path)
/// With `--json` the output is a single JSON object consumed by the web frontend.
enum RealArea {
    struct BBox { let south, west, north, east: Double
        var centerLat: Double { (south + north) / 2 }
        var centerLon: Double { (west + east) / 2 }
    }
    static let clemson = BBox(south: 34.669, west: -82.849, north: 34.691, east: -82.823)

    // MARK: disk cache

    static func cacheDir(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("AnumaanSim/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: roads (Overpass)

    static let overpassEndpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
    ]
    static func fetchOverpass(_ b: BBox) async throws -> Data {
        let q = Overpass.walkingQuery(south: b.south, west: b.west, north: b.north, east: b.east)
        let body = "data=" + (q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q)
        var lastErr: Error = NSError(domain: "overpass", code: 0)
        for ep in overpassEndpoints {
            do {
                var req = URLRequest(url: URL(string: ep)!)
                req.httpMethod = "POST"; req.timeoutInterval = 90
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                req.httpBody = body.data(using: .utf8)
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    throw NSError(domain: "overpass", code: (resp as? HTTPURLResponse)?.statusCode ?? 0)
                }
                return data
            } catch { lastErr = error }
        }
        throw lastErr
    }

    // MARK: DEM (Terrarium tiles) — pure-Swift PNG, no Apple frameworks

    static let demHost = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium"

    private struct DataSource: PNG.BytestreamSource {
        var bytes: [UInt8]; var pos = 0
        mutating func read(count: Int) -> [UInt8]? {
            guard pos + count <= bytes.count else { return nil }
            defer { pos += count }
            return Array(bytes[pos ..< pos + count])
        }
    }

    static func decodePNG(_ data: Data) -> [Int16]? {
        var src = DataSource(bytes: Array(data))
        guard let image = try? PNG.Data.Rectangular.decompress(stream: &src) else { return nil }
        let rgba = image.unpack(as: PNG.RGBA<UInt8>.self)
        guard rgba.count == 256 * 256 else { return nil }
        return rgba.map { px in
            Int16(Swift.max(-32768, Swift.min(32767,
                Terrarium.elevation(r: px.r, g: px.g, b: px.b).rounded())))
        }
    }

    static func chooseZoom(_ b: BBox) -> Int? {
        (8...13).reversed().first {
            TileMath.tiles(south: b.south, west: b.west, north: b.north, east: b.east, z: $0).count <= 90
        }
    }

    static func fetchDEM(_ b: BBox) async throws -> TerrariumDEM {
        guard let z = chooseZoom(b) else { throw NSError(domain: "dem", code: 1) }
        let r = TileMath.tileRange(south: b.south, west: b.west, north: b.north, east: b.east, z: z)
        let cols = r.xMax - r.xMin + 1, rows = r.yMax - r.yMin + 1
        let width = cols * 256, height = rows * 256
        var elev = [Int16](repeating: 0, count: width * height)
        try await withThrowingTaskGroup(of: (Int, Int, [Int16]).self) { group in
            for ty in r.yMin...r.yMax { for tx in r.xMin...r.xMax {
                group.addTask {
                    let url = URL(string: "\(demHost)/\(z)/\(tx)/\(ty).png")!
                    let (data, resp) = try await URLSession.shared.data(from: url)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200,
                          let px = decodePNG(data) else { throw NSError(domain: "dem", code: 2) }
                    return (tx - r.xMin, ty - r.yMin, px)
                }
            }}
            for try await (col, row, px) in group {
                let ox = col * 256, oy = row * 256
                for ry in 0..<256 {
                    let dst = (oy + ry) * width + ox, src2 = ry * 256
                    for cx in 0..<256 { elev[dst + cx] = px[src2 + cx] }
                }
            }
        }
        return TerrariumDEM(z: z, px0: r.xMin * 256, py0: r.yMin * 256,
                            width: width, height: height, elev: elev,
                            originLat: b.centerLat, originLon: b.centerLon)
    }

    // MARK: binary DEM cache

    static func writeDEM(_ dem: TerrariumDEM, to url: URL) {
        var d = Data()
        for v in [dem.z, dem.px0, dem.py0, dem.width, dem.height] {
            var x = Int32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        }
        for v in [dem.originLat, dem.originLon] {
            var bits = v.bitPattern.littleEndian; withUnsafeBytes(of: &bits) { d.append(contentsOf: $0) }
        }
        dem.elev.withUnsafeBytes { d.append(contentsOf: $0) }
        try? d.write(to: url)
    }

    static func readDEM(from url: URL) -> TerrariumDEM? {
        guard let d = try? Data(contentsOf: url), d.count >= 36 else { return nil }
        let base = d.startIndex
        func u32(_ off: Int) -> UInt32 {
            let s = base + off
            return UInt32(d[s]) | UInt32(d[s+1]) << 8 | UInt32(d[s+2]) << 16 | UInt32(d[s+3]) << 24
        }
        func i32(_ off: Int) -> Int { Int(Int32(bitPattern: u32(off))) }
        func f64(_ off: Int) -> Double {
            let s = base + off
            var bits: UInt64 = 0
            for k in 0..<8 { bits |= UInt64(d[s+k]) << (8*k) }
            return Double(bitPattern: bits)
        }
        let z = i32(0), px0 = i32(4), py0 = i32(8), w = i32(12), h = i32(16)
        let oLat = f64(20), oLon = f64(28), header = 36, n = w * h
        guard w > 0, h > 0, d.count >= header + n * 2 else { return nil }
        var elev = [Int16](repeating: 0, count: n)
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<n { let p = header + 2*i; elev[i] = Int16(bitPattern: UInt16(raw[p]) | UInt16(raw[p+1]) << 8) }
        }
        return TerrariumDEM(z: z, px0: px0, py0: py0, width: w, height: h,
                            elev: elev, originLat: oLat, originLon: oLon)
    }

    // MARK: meter-frame build

    struct Built {
        let nodes: [GeoPoint]; let adjacency: [[Int]]
        let namedRoads: [(name: String, segments: [(GeoPoint, GeoPoint)])]
        let landmarks: [(p: GeoPoint, kind: String)]
        let meters: (Double, Double) -> GeoPoint
        let roadIndex: RoadIndex
    }

    static func build(graph: RoadGraph, centerLat: Double, centerLon: Double) -> Built {
        let mLat = 111_320.0, cosLat = cos(centerLat * .pi / 180)
        let meters: (Double, Double) -> GeoPoint = { lat, lon in
            GeoPoint(x: (lon - centerLon) * mLat * cosLat, y: (lat - centerLat) * mLat)
        }

        let snap = graph.snapshot()
        var idx: [String: Int] = [:]; var nodes: [GeoPoint] = []
        for n in snap.nodes { idx[n.id] = nodes.count; nodes.append(meters(n.lat, n.lon)) }
        var adj = [[Int]](repeating: [], count: nodes.count)
        var named: [String: [(GeoPoint, GeoPoint)]] = [:]
        var segments: [(GeoPoint, GeoPoint)] = []
        for e in snap.edges {
            guard let a = idx[e.from], let b = idx[e.to] else { continue }
            if !adj[a].contains(b) { adj[a].append(b) }
            if !adj[b].contains(a) { adj[b].append(a) }
            segments.append((nodes[a], nodes[b]))
            if !e.name.isEmpty, e.name != "road", e.name != "unnamed road" {
                named[e.name, default: []].append((nodes[a], nodes[b]))
            }
        }
        var lm: [(p: GeoPoint, kind: String)] = []
        for n in snap.nodes {
            guard let i = idx[n.id] else { continue }
            if n.type == "stop_sign"           { lm.append((nodes[i], "stop_sign")) }
            else if n.type == "traffic_light"  { lm.append((nodes[i], "traffic_light")) }
            else if graph.degree(n.id) >= 3    { lm.append((nodes[i], "intersection")) }
            else if graph.degree(n.id) == 1    { lm.append((nodes[i], "dead_end")) }
        }
        let roadIndex = RoadIndex(segments: segments)
        return Built(nodes: nodes, adjacency: adj,
                     namedRoads: named.map { (name: $0.key, segments: $0.value) },
                     landmarks: lm, meters: meters, roadIndex: roadIndex)

    }

    // MARK: heading stats

    struct HeadingStats {
        let stdDev: Double
        let totalChangeDeg: Double
        let significantTurns: Int  // turns > 30°
    }

    static func headingStats(_ headings: [Double]) -> HeadingStats {
        guard headings.count >= 2 else { return HeadingStats(stdDev: 0, totalChangeDeg: 0, significantTurns: 0) }
        var total = 0.0, sigTurns = 0
        for i in 1..<headings.count {
            var d = abs(headings[i] - headings[i-1])
            if d > 180 { d = 360 - d }
            total += d
            if d > 30 { sigTurns += 1 }
        }
        // Circular std dev (via mean resultant length)
        let sx = headings.map { sin($0 * .pi / 180) }.reduce(0, +) / Double(headings.count)
        let cx = headings.map { cos($0 * .pi / 180) }.reduce(0, +) / Double(headings.count)
        let R = sqrt(sx*sx + cx*cx)
        let circStdDev = R < 1 ? sqrt(-2 * log(R)) * 180 / .pi : 0
        return HeadingStats(stdDev: circStdDev, totalChangeDeg: total, significantTurns: sigTurns)
    }

    // MARK: run

    static func run(_ customBBox: BBox? = nil, name: String = "clemson",
                    fromLL: (Double, Double)? = nil, toLL: (Double, Double)? = nil,
                    pathLL: [(Double, Double)]? = nil,
                    mode: String = "road",
                    json: Bool = false,
                    benchmark: Bool = false,
                    minQuestions: Int = 1) async throws {
        let stderr = FileHandle.standardError
        func log(_ s: String) { if !json && !benchmark { print(s) }
            else { stderr.write(Data((s + "\n").utf8)) } }

        log("=== AnumaanSim — REAL area: \(name) ===")

        var b = customBBox ?? clemson
        if let pathLL, !pathLL.isEmpty {
            var s = pathLL[0].0, w = pathLL[0].1, n = pathLL[0].0, e = pathLL[0].1
            for pt in pathLL {
                s = min(s, pt.0); w = min(w, pt.1)
                n = max(n, pt.0); e = max(e, pt.1)
            }
            // Add padding of 0.005 degrees (~550 meters) on all sides so candidates can be matched comfortably
            let padLat = 0.005, padLon = 0.005 / cos(s * .pi / 180)
            
            let pathCenterLat = (s + n) / 2
            let pathCenterLon = (w + e) / 2
            let isNearInitial = pathCenterLat >= b.south && pathCenterLat <= b.north &&
                                pathCenterLon >= b.west && pathCenterLon <= b.east
            
            if isNearInitial {
                b = BBox(south: min(b.south, s - padLat),
                         west: min(b.west, w - padLon),
                         north: max(b.north, n + padLat),
                         east: max(b.east, e + padLon))
            } else {
                b = BBox(south: s - padLat,
                         west: w - padLon,
                         north: n + padLat,
                         east: e + padLon)
            }
        }

        let boundsStr = String(format: "_%.3f_%.3f_%.3f_%.3f", b.south, b.west, b.north, b.east)
        let dir = cacheDir(name)
        let ovURL = dir.appendingPathComponent("overpass_walk\(boundsStr).json")
        let demURL = dir.appendingPathComponent("dem\(boundsStr).bin")

        let graph: RoadGraph
        if let cached = try? Data(contentsOf: ovURL), !cached.isEmpty {
            log("Roads: using cached Overpass (\(cached.count / 1024) KB).")
            graph = try Overpass.buildGraph(from: cached)
        } else if mode == "offtrail" {
            // Off-trail only uses roads to mask candidates near pavement — they're
            // optional out in the backcountry. A flaky or empty Overpass response
            // must not kill the run; fall back to an empty road graph (no mask).
            do {
                log("Roads: downloading from Overpass (optional for off-trail)…")
                let data = try await fetchOverpass(b)
                try? data.write(to: ovURL)
                graph = try Overpass.buildGraph(from: data)
            } catch {
                log("Roads: Overpass unavailable (\(error)); continuing with no road mask.")
                graph = RoadGraph()
            }
        } else {
            log("Roads: downloading from Overpass…")
            let data = try await fetchOverpass(b)
            try? data.write(to: ovURL)
            graph = try Overpass.buildGraph(from: data)
        }

        let dem: TerrariumDEM
        if let cached = readDEM(from: demURL) {
            log("DEM: using cached tiles (\(cached.width)x\(cached.height) px, z\(cached.z)).")
            dem = cached
        } else {
            log("DEM: downloading Terrarium tiles for expanded bounds…")
            dem = try await fetchDEM(b)
            writeDEM(dem, to: demURL)
        }

        let center = (lat: dem.originLat, lon: dem.originLon)
        let built = build(graph: graph, centerLat: center.lat, centerLon: center.lon)

        // Build the walk polyline
        let poly: [GeoPoint]
        let routeStartLL: (lat: Double, lon: Double)
        let routeEndLL:   (lat: Double, lon: Double)

        if let pathLL, pathLL.count >= 2 {
            // User drew their own path — use it directly, no routing needed
            poly = pathLL.map { built.meters($0.0, $0.1) }
            routeStartLL = (pathLL.first!.0, pathLL.first!.1)
            routeEndLL   = (pathLL.last!.0,  pathLL.last!.1)
            log("Path: \(pathLL.count) waypoints drawn by user, ~\(Int(polylineLength(poly))) m.")
        } else {
            // Find shortest road path between from/to
            func at(_ fx: Double, _ fy: Double) -> (lat: Double, lon: Double) {
                (b.south + fy * (b.north - b.south), b.west + fx * (b.east - b.west))
            }
            let sLL = fromLL.map { (lat: $0.0, lon: $0.1) } ?? at(0.30, 0.30)
            let dLL = toLL.map   { (lat: $0.0, lon: $0.1) } ?? at(0.62, 0.66)
            guard let sId = graph.nearestNode(lat: sLL.lat, lon: sLL.lon),
                  let dId = graph.nearestNode(lat: dLL.lat, lon: dLL.lon),
                  sId != dId,
                  let path = graph.shortestPath(from: sId, to: dId), path.count >= 4 else {
                let msg = "Couldn't find a road path between those points."
                if json { print("{\"error\":\"\(msg)\"}") } else { print(msg) }
                return
            }
            poly = path.compactMap { id in graph.nodes[id].map { built.meters($0.lat, $0.lon) } }
            routeStartLL = sLL; routeEndLL = dLL
            log("Graph: \(graph.nodes.count) nodes. Path: \(path.count) nodes, ~\(Int(polylineLength(poly))) m.")
        }

        guard let trueEnd = poly.last, poly.count >= 2 else {
            let msg = "Walk too short."
            if json { print("{\"error\":\"\(msg)\"}") } else { print(msg) }
            return
        }

        let stepM = 15.0
        var rng = LCG(seed: 0xC0FFEE)

        // Synthesize fine-grained (1-meter resolution) path samples to capture precise headings and altitudes,
        // then bin them using PathSiphon.build to perfectly align the simulated observation profile
        // with the DEM contour matching grid.
        let totalLen = polylineLength(poly)
        var dists: [Double] = []
        var alts: [Double] = []
        var hdgs: [Double] = []
        let baseElev = dem.elevation(x: poly[0].x, y: poly[0].y) ?? 0

        var d = 0.0
        while d <= totalLen {
            let s = sampleAlong(poly, at: d)
            dists.append(d)
            let rawE = dem.elevation(x: s.pos.x, y: s.pos.y) ?? baseElev
            alts.append(rawE - baseElev + rng.gauss(0.5)) // add baro noise
            hdgs.append(s.heading + rng.gauss(4.0))        // add heading noise
            d += 1.0
        }

        let binned = PathSiphon.build(distances: dists, altitudes: alts, headings: hdgs, step: stepM)
        let walkHeadings = binned.headings
        let walkCumElev = binned.profile

        guard walkHeadings.count >= 3 else {
            let msg = "Walk too short to localise (need > 45 m)."
            if json { print("{\"error\":\"\(msg)\"}") } else { print(msg) }
            return
        }

        // True elevation profile (unsensored / no noise, aligned with binned steps)
        var trueDists: [Double] = []
        var trueAlts: [Double] = []
        var trueHdgs: [Double] = []
        d = 0.0
        while d <= totalLen {
            let s = sampleAlong(poly, at: d)
            trueDists.append(d)
            trueAlts.append((dem.elevation(x: s.pos.x, y: s.pos.y) ?? baseElev) - baseElev)
            trueHdgs.append(s.heading)
            d += 1.0
        }
        let trueBinned = PathSiphon.build(distances: trueDists, altitudes: trueAlts, headings: trueHdgs, step: stepM)
        let trueElev = trueBinned.profile

        let hStats = headingStats(walkHeadings)

        let minPt = dem.meters(lat: b.south, lon: b.west)
        let maxPt = dem.meters(lat: b.north, lon: b.east)

        let cloud: HypothesisCloud
        let preQLead: GeoPoint
        let preQCurrent: GeoPoint
        let preQErrorM: Double
        let preQConc: Double
        let preQBestLL: (lat: Double, lon: Double)?

        if mode == "road" {
            let matcher = RouteMatcher(nodes: built.nodes, adjacency: built.adjacency, dem: dem)
            matcher.seed(targetCount: 15000)
            
            let outsideMask: (GeoPoint) -> Bool = { p in
                p.x < minPt.x || p.x > maxPt.x || p.y < minPt.y || p.y > maxPt.y
            }
            matcher.mask(outsideMask)

            for i in walkHeadings.indices {
                matcher.advance(distanceM: stepM, headingDeg: walkHeadings[i], cumElevM: walkCumElev[i])
            }

            preQCurrent = matcher.summary(radiusM: 120)?.estimate ?? matcher.estimate() ?? GeoPoint(x: 0, y: 0)
            preQLead = preQCurrent
            preQErrorM = preQCurrent.distance(to: trueEnd)
            preQConc = matcher.summary(radiusM: 120)?.concentration ?? 0
            preQBestLL = dem.latLon(x: preQCurrent.x, y: preQCurrent.y)

            log("After walk: \(matcher.walkerCount) hypotheses, lead concentration \(pctStr(preQConc)), " +
                "pre-Q error \(String(format: "%.0f", preQErrorM)) m.")

            cloud = RouteCloud(matcher)
        } else {
            let areaM2 = (maxPt.x - minPt.x) * (maxPt.y - minPt.y)
            let targetCount = 15000
            let spacing = Swift.max(28.0, (areaM2 / Double(Swift.max(1, targetCount))).squareRoot())
            var candidates: [GeoPoint] = []
            var cy = minPt.y
            while cy <= maxPt.y {
                var cx = minPt.x
                while cx <= maxPt.x {
                    candidates.append(GeoPoint(x: cx, y: cy))
                    cx += spacing
                }
                cy += spacing
            }

            let matcher = CurveMatcher(dem: dem, roads: nil, candidates: candidates)
            matcher.profileStep = stepM
            // Mask out candidates near paved roads (matching the iOS .offtrail behavior)
            matcher.maskOut { built.roadIndex.nearestDistance(to: $0) <= 20 }
            matcher.scorePath(headings: walkHeadings, profile: walkCumElev)

            var endX = 0.0, endY = 0.0
            for h in walkHeadings {
                let r = h * .pi / 180
                endX += sin(r) * stepM
                endY += cos(r) * stepM
            }
            let endOffset = GeoPoint(x: endX, y: endY)

            preQLead = matcher.lead
            preQCurrent = GeoPoint(x: preQLead.x + endOffset.x, y: preQLead.y + endOffset.y)
            preQErrorM = preQCurrent.distance(to: trueEnd)
            preQConc = matcher.leadConcentration(radiusM: 120)
            preQBestLL = dem.latLon(x: preQCurrent.x, y: preQCurrent.y)

            log("After walk: \(matcher.candidates.count) hypotheses, lead concentration \(pctStr(preQConc)), " +
                "pre-Q error \(String(format: "%.0f", preQErrorM)) m.")

            cloud = CurveCloud(matcher, endOffset: endOffset)
        }

        let endLL = dem.latLon(x: trueEnd.x, y: trueEnd.y)

        // Build interrogation map (shared between JSON and terminal modes)
        let iMap = InterrogationMap(
            features: FeatureField(originLat: center.lat, originLon: center.lon, features: []),
            dem: dem, landmarks: built.landmarks, namedRoads: built.namedRoads, pois: [])
        let session = RecoverySession(map: iMap)

        if benchmark {
            // Batch mode: run oracle Q&A and emit one compact JSON line for the Python benchmarker.
            // minQuestions: don't accept a location until the engine has answered at least N questions
            // across one or more rounds, testing whether more confirmation improves accuracy.
            var locatedPoint: GeoPoint? = nil
            var locatedConc = 0.0
            var asked = 0
            var outcome = session.startRound(cloud: cloud, natureMode: mode == "offtrail", heading: walkHeadings.last)
            outerBenchLoop: while asked < 16 {
                switch outcome {
                case .ask(let q):
                    asked += 1
                    let yes = q.predicate(trueEnd)
                    outcome = session.answer(yes, cloud: cloud)
                    if case .located(let p, _, let conc) = outcome {
                        locatedPoint = p; locatedConc = conc
                        if asked >= minQuestions { break outerBenchLoop }
                        // Need more questions — restart a new round from same position
                        outcome = session.startRound(cloud: cloud, natureMode: mode == "offtrail", heading: walkHeadings.last)
                    }
                    if case .needWalk = outcome { break outerBenchLoop }
                case .located(let p, _, let conc):
                    locatedPoint = p; locatedConc = conc
                    if asked >= minQuestions { break outerBenchLoop }
                    outcome = session.startRound(cloud: cloud, natureMode: mode == "offtrail", heading: walkHeadings.last)
                case .needWalk:
                    break outerBenchLoop
                }
            }
            let located = locatedPoint != nil
            let locErrStr = locatedPoint.map { String(format: "%.1f", $0.distance(to: trueEnd)) } ?? "null"
            let walkDistM = Int(totalLen.rounded())

            // Elevation metrics from the noisy cumulative profile
            let elevGain = zip(walkCumElev, walkCumElev.dropFirst())
                .reduce(0.0) { acc, pair in pair.1 > pair.0 ? acc + (pair.1 - pair.0) : acc }
            let elevMin = walkCumElev.min() ?? 0.0
            let elevMax = walkCumElev.max() ?? 0.0

            // Convert located point to lat/lon for the UI
            let locLL = locatedPoint.map { dem.latLon(x: $0.x, y: $0.y) }
            let locLatStr = locLL.map { String(format: "%.6f", $0.lat) } ?? "null"
            let locLonStr = locLL.map { String(format: "%.6f", $0.lon) } ?? "null"

            // True endpoint lat/lon so the UI can draw a line from engine guess → truth
            let trueLL = dem.latLon(x: trueEnd.x, y: trueEnd.y)

            print("{\"located\":\(located ? "true" : "false")"
                + ",\"locatedErrorM\":\(locErrStr)"
                + ",\"locatedConc\":\(String(format: "%.4f", locatedConc))"
                + ",\"locatedLat\":\(locLatStr)"
                + ",\"locatedLon\":\(locLonStr)"
                + ",\"trueEndLat\":\(String(format: "%.6f", trueLL.lat))"
                + ",\"trueEndLon\":\(String(format: "%.6f", trueLL.lon))"
                + ",\"qAnsweredCount\":\(asked)"
                + ",\"significantTurns\":\(hStats.significantTurns)"
                + ",\"headingStdDev\":\(String(format: "%.2f", hStats.stdDev))"
                + ",\"totalHeadingChangeDeg\":\(String(format: "%.1f", hStats.totalChangeDeg))"
                + ",\"elevGainM\":\(String(format: "%.1f", elevGain))"
                + ",\"elevRangeM\":\(String(format: "%.1f", elevMax - elevMin))"
                + ",\"walkSteps\":\(walkHeadings.count)"
                + ",\"walkDistanceM\":\(walkDistM)"
                + ",\"preQuestionErrorM\":\(String(format: "%.1f", preQErrorM))"
                + ",\"preQuestionConc\":\(String(format: "%.4f", preQConc))"
                + ",\"minQuestionsUsed\":\(minQuestions)}")
        } else if json {
            // Interactive mode: pre-evaluate the full question bank at every hypothesis
            // so the browser can run the Q&A loop without extra server round-trips.
            let allQs = session.buildFullQuestionBank(cloud: cloud)
            let cloudSample = cloud.weightedSample(max: 600)
            let qTexts  = allQs.map { $0.text }
            let qNamed  = allQs.map { $0.named }
            // For each hypothesis, evaluate every question (bool array)
            let qAnswers = cloudSample.map { hyp in allQs.map { q in q.predicate(hyp.point) } }

            emitJSON(dem: dem, poly: poly, trueEnd: trueEnd, endLL: endLL,
                     hypotheses: cloudSample,
                     qTexts: qTexts, qNamed: qNamed, qAnswers: qAnswers,
                     walkSteps: walkHeadings.count,
                     startLL: routeStartLL, destLL: routeEndLL,
                     trueElev: trueElev, noisyElev: walkCumElev,
                     headings: walkHeadings, hStats: hStats,
                     preQBestLL: preQBestLL, preQErrorM: preQErrorM, preQConc: preQConc)
        } else {
            // Terminal / oracle mode: auto-answer using true endpoint
            var transcript: [(String, Bool)] = []
            var locatedPoint: GeoPoint? = nil
            var locatedConc = 0.0
            var outcome = session.startRound(cloud: cloud, natureMode: mode == "offtrail", heading: walkHeadings.last)
            var asked = 0
            outerLoop: while asked < 16 {
                switch outcome {
                case .ask(let q):
                    asked += 1
                    let yes = q.predicate(trueEnd)
                    transcript.append((q.text, yes))
                    log("  Q\(asked): \(q.text)  ->  \(yes ? "YES" : "no")")
                    outcome = session.answer(yes, cloud: cloud)
                    if case .located(let p, _, let conc) = outcome {
                        locatedPoint = p; locatedConc = conc; break outerLoop
                    }
                    if case .needWalk = outcome { break outerLoop }
                case .located(let p, _, let conc):
                    locatedPoint = p; locatedConc = conc; break outerLoop
                case .needWalk:
                    break outerLoop
                }
            }
            let errorM = locatedPoint.map { $0.distance(to: trueEnd) } ?? 0
            if let lp = locatedPoint {
                let ll = dem.latLon(x: lp.x, y: lp.y)
                log("  => LOCATED (\(pctStr(locatedConc))). Error: \(String(format: "%.1f", errorM)) m " +
                    "(\(String(format: "%.5f", ll.lat)), \(String(format: "%.5f", ll.lon)))")
            } else { log("  => not located after \(asked) questions.") }
            log("True end: (\(String(format: "%.5f", endLL.lat)), \(String(format: "%.5f", endLL.lon)))")
            log("Heading: σ=\(String(format: "%.1f", hStats.stdDev))°, " +
                "\(hStats.significantTurns) turns >30°, total change \(String(format: "%.0f", hStats.totalChangeDeg))°")
        }
    }

    // MARK: JSON output

    private static func emitJSON(dem: TerrariumDEM, poly: [GeoPoint],
                                 trueEnd: GeoPoint, endLL: (lat: Double, lon: Double),
                                 hypotheses: [(point: GeoPoint, weight: Double)],
                                 qTexts: [String], qNamed: [Bool],
                                 qAnswers: [[Bool]],
                                 walkSteps: Int,
                                 startLL: (lat: Double, lon: Double),
                                 destLL: (lat: Double, lon: Double),
                                 trueElev: [Double], noisyElev: [Double],
                                 headings: [Double], hStats: HeadingStats,
                                 preQBestLL: (lat: Double, lon: Double)?,
                                 preQErrorM: Double, preQConc: Double) {
        func ll(_ p: GeoPoint) -> String {
            let c = dem.latLon(x: p.x, y: p.y)
            return "[\(String(format: "%.6f", c.lat)),\(String(format: "%.6f", c.lon))]"
        }
        func f1(_ v: Double) -> String { String(format: "%.1f", v) }
        func f2(_ v: Double) -> String { String(format: "%.4f", v) }

        let routeArr  = poly.map { ll($0) }.joined(separator: ",")
        // Hypotheses include weight as third element: [lat, lon, weight]
        let hypoArr = hypotheses.map { h -> String in
            let c = dem.latLon(x: h.point.x, y: h.point.y)
            return "[\(String(format: "%.6f", c.lat)),\(String(format: "%.6f", c.lon)),\(h.weight)]"
        }.joined(separator: ",")
        let preQStr = preQBestLL.map { "[\(String(format: "%.6f", $0.lat)),\(String(format: "%.6f", $0.lon))]" } ?? "null"
        let elevArr  = trueElev.map { f1($0) }.joined(separator: ",")
        let noisyArr = noisyElev.map { f1($0) }.joined(separator: ",")
        let hdgArr   = headings.map { f1($0) }.joined(separator: ",")
        // questions: [{text, named}, ...]
        let questArr = zip(qTexts, qNamed).map { t, n in
            "{\(jsonStr("text")):\(jsonStr(t)),\(jsonStr("named")):\(n ? "true" : "false")}"
        }.joined(separator: ",")
        // questionAnswers: [[bool, bool, ...], ...] — one row per hypothesis
        let qaArr = qAnswers.map { row in
            "[" + row.map { $0 ? "true" : "false" }.joined(separator: ",") + "]"
        }.joined(separator: ",")

        print("""
        {"area":"clemson",
         "walkSteps":\(walkSteps),
         "walkDistanceM":\(walkSteps * 15),
         "start":[\(String(format: "%.6f", startLL.lat)),\(String(format: "%.6f", startLL.lon))],
         "trueEnd":[\(String(format: "%.6f", endLL.lat)),\(String(format: "%.6f", endLL.lon))],
         "preQuestionBest":\(preQStr),
         "preQuestionErrorM":\(f1(preQErrorM)),
         "preQuestionConc":\(f2(preQConc)),
         "route":[\(routeArr)],
         "hypotheses":[\(hypoArr)],
         "questions":[\(questArr)],
         "questionAnswers":[\(qaArr)],
         "elevProfile":[\(elevArr)],
         "noisyElev":[\(noisyArr)],
         "headings":[\(hdgArr)],
         "headingStdDev":\(f1(hStats.stdDev)),
         "significantTurns":\(hStats.significantTurns),
         "totalHeadingChangeDeg":\(f1(hStats.totalChangeDeg))}
        """)
    }

    private static func jsonStr(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
