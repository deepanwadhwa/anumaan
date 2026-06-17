import Foundation
import CoreLocation
import AnumaanCore

/// A DEM that samples whichever downloaded patch covers a point — so elevation
/// works across the whole union of downloads in one global meter frame.
final class AtlasDEM: DEMProvider {
    let originLat: Double, originLon: Double
    struct Part { let s, w, n, e: Double; let dem: TerrariumDEM }
    let parts: [Part]
    private let mLat = 111_320.0
    init(originLat: Double, originLon: Double, parts: [Part]) {
        self.originLat = originLat; self.originLon = originLon; self.parts = parts
    }
    func elevation(x: Double, y: Double) -> Double? {
        let lat = originLat + y / mLat
        let lon = originLon + x / (mLat * cos(originLat * .pi / 180))
        for p in parts where lat >= p.s && lat <= p.n && lon >= p.w && lon <= p.e {
            let pt = p.dem.meters(lat: lat, lon: lon)
            if let e = p.dem.elevation(x: pt.x, y: pt.y) { return e }
        }
        return nil
    }
}

/// The merged offline map across all downloaded patches: one DEM, one road graph
/// (joined by shared OSM node IDs so routing crosses chunk boundaries), merged
/// trails/features/landmarks — all in one global meter frame around `origin`.
final class Atlas {
    let patches: [AreaPatch]
    let originLat: Double, originLon: Double
    let dem: AtlasDEM
    let graph: RoadGraph
    let roads: RoadIndex
    let trails: RoadIndex?
    let features: FeatureField
    let namedRoadSegs: [String: [(GeoPoint, GeoPoint)]]
    let pois: [(name: String, p: GeoPoint)]
    let landmarks: [(p: GeoPoint, kind: String)]
    let coverage: [(s: Double, w: Double, n: Double, e: Double)]
    private let mLat = 111_320.0

    var center: CLLocationCoordinate2D {
        .init(latitude: (coverage.map { $0.s }.min()! + coverage.map { $0.n }.max()!) / 2,
              longitude: (coverage.map { $0.w }.min()! + coverage.map { $0.e }.max()!) / 2)
    }
    /// Half the union's diagonal — the scatter radius for "lost anywhere in here".
    var radiusM: Double {
        let s = coverage.map { $0.s }.min()!, n = coverage.map { $0.n }.max()!
        let w = coverage.map { $0.w }.min()!, e = coverage.map { $0.e }.max()!
        let dy = (n - s) * mLat, dx = (e - w) * mLat * cos(originLat * .pi / 180)
        return (dx * dx + dy * dy).squareRoot() / 2
    }

    func meters(lat: Double, lon: Double) -> GeoPoint {
        GeoPoint(x: (lon - originLon) * mLat * cos(originLat * .pi / 180), y: (lat - originLat) * mLat)
    }

    /// The road network as a node/adjacency graph in the global meter frame —
    /// what RouteMatcher needs to snap a walk onto the streets.
    func roadGraphMeters() -> (nodes: [GeoPoint], adjacency: [[Int]]) {
        let snap = graph.snapshot()
        var idx: [String: Int] = [:]; var nodes: [GeoPoint] = []
        for n in snap.nodes { idx[n.id] = nodes.count; nodes.append(meters(lat: n.lat, lon: n.lon)) }
        var adj = [[Int]](repeating: [], count: nodes.count)
        for e in snap.edges {
            guard let a = idx[e.from], let b = idx[e.to] else { continue }
            if !adj[a].contains(b) { adj[a].append(b) }      // undirected: you can walk a road either way
            if !adj[b].contains(a) { adj[b].append(a) }
        }
        return (nodes, adj)
    }

    /// Road graph WITH per-edge speed limits (m/s) for driving map-matching —
    /// speeds parallel the adjacency lists.
    func drivingGraphMeters() -> (nodes: [GeoPoint], adjacency: [[Int]], speeds: [[Double]]) {
        let snap = graph.snapshot()
        var idx: [String: Int] = [:]; var nodes: [GeoPoint] = []
        for n in snap.nodes { idx[n.id] = nodes.count; nodes.append(meters(lat: n.lat, lon: n.lon)) }
        var adj = [[Int]](repeating: [], count: nodes.count)
        var spd = [[Double]](repeating: [], count: nodes.count)
        func add(_ a: Int, _ b: Int, _ s: Double) {
            if let k = adj[a].firstIndex(of: b) { spd[a][k] = max(spd[a][k], s) }
            else { adj[a].append(b); spd[a].append(s) }
        }
        for e in snap.edges {
            guard let a = idx[e.from], let b = idx[e.to] else { continue }
            add(a, b, e.speed); add(b, a, e.speed)
        }
        return (nodes, adj, spd)
    }

    /// Trails as a node/adjacency graph (built from the trail polylines, joining
    /// shared endpoints) — nil if this atlas has no trails.
    func trailGraphMeters() -> (nodes: [GeoPoint], adjacency: [[Int]])? {
        var nodes: [GeoPoint] = []; var key: [Int64: Int] = [:]; var adj: [[Int]] = []
        func node(_ p: GeoPoint) -> Int {
            let k = Int64((p.x / 3).rounded()) &* 1_000_003 &+ Int64((p.y / 3).rounded())   // 3 m quantise
            if let i = key[k] { return i }
            let i = nodes.count; key[k] = i; nodes.append(p); adj.append([]); return i
        }
        for f in features.features where f.kind == .trail && f.points.count >= 2 {
            for i in 1..<f.points.count {
                let p0 = f.points[i - 1], p1 = f.points[i]
                // Skip "trails" that hug a road — those are SIDEWALKS, not hiking
                // trails. Including them made trail mode snap onto the streets.
                let mid = GeoPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
                if roads.nearestDistance(to: mid) <= 25 { continue }
                let a = node(p0), b = node(p1)
                if a != b { if !adj[a].contains(b) { adj[a].append(b) }; if !adj[b].contains(a) { adj[b].append(a) } }
            }
        }
        return nodes.isEmpty ? nil : (nodes, adj)
    }
    func latLon(x: Double, y: Double) -> (lat: Double, lon: Double) {
        (originLat + y / mLat, originLon + x / (mLat * cos(originLat * .pi / 180)))
    }

    private init(patches: [AreaPatch], graphs: [RoadGraph], dems: [(AreaPatch, TerrariumDEM)],
                 feats: [(AreaPatch, FeatureField)]) {
        self.patches = patches
        coverage = patches.map { ($0.south, $0.west, $0.north, $0.east) }
        originLat = patches.map(\.lat).reduce(0, +) / Double(patches.count)
        originLon = patches.map(\.lon).reduce(0, +) / Double(patches.count)
        let oLat = originLat, oLon = originLon, m = mLat
        func toGlobal(lat: Double, lon: Double) -> GeoPoint {
            GeoPoint(x: (lon - oLon) * m * cos(oLat * .pi / 180), y: (lat - oLat) * m)
        }

        dem = AtlasDEM(originLat: oLat, originLon: oLon,
                       parts: dems.map { .init(s: $0.0.south, w: $0.0.west, n: $0.0.north, e: $0.0.east, dem: $0.1) })

        // Merge road graphs by node id (shared OSM ids join boundaries) → one graph.
        let g = RoadGraph()
        for graph in graphs { for n in graph.snapshot().nodes { g.addNode(n.id, lat: n.lat, lon: n.lon, type: n.type) } }
        for graph in graphs { for e in graph.snapshot().edges { g.addEdge(e.from, e.to, name: e.name, speed: e.speed, oneway: true) } }
        graph = g

        // Roads / named roads / landmarks in the global frame.
        let snap = g.snapshot()
        var pt: [String: GeoPoint] = [:]
        for n in snap.nodes { pt[n.id] = toGlobal(lat: n.lat, lon: n.lon) }
        var segs: [(GeoPoint, GeoPoint)] = []; var named: [String: [(GeoPoint, GeoPoint)]] = [:]
        for e in snap.edges {
            guard let a = pt[e.from], let b = pt[e.to] else { continue }
            segs.append((a, b))
            if !e.name.isEmpty, e.name != "road", e.name != "unnamed road" { named[e.name, default: []].append((a, b)) }
        }
        roads = RoadIndex(segments: segs)
        namedRoadSegs = named
        var lm: [(GeoPoint, String)] = []
        for n in snap.nodes {
            guard let p = pt[n.id] else { continue }
            if n.type == "stop_sign"          { lm.append((p, "stop_sign")) }
            else if n.type == "traffic_light" { lm.append((p, "traffic_light")) }
            else if g.degree(n.id) >= 3       { lm.append((p, "intersection")) }
            else if g.degree(n.id) == 1       { lm.append((p, "dead_end")) }
        }
        landmarks = lm

        // Features / trails / POIs converted from each patch frame → global frame.
        var allFeats: [MapFeature] = []; var trailSegs: [(GeoPoint, GeoPoint)] = []; var poiList: [(String, GeoPoint)] = []
        for (_, ff) in feats {
            let fo = ff.originLat, foL = ff.originLon
            func g2(_ p: GeoPoint) -> GeoPoint {
                let lat = fo + p.y / m, lon = foL + p.x / (m * cos(fo * .pi / 180))
                return toGlobal(lat: lat, lon: lon)
            }
            for f in ff.features {
                let gpts = f.points.map(g2)
                allFeats.append(MapFeature(kind: f.kind, isArea: f.isArea, points: gpts, name: f.name))
                if f.kind == .trail, gpts.count >= 2 { for i in 1..<gpts.count { trailSegs.append((gpts[i - 1], gpts[i])) } }
                else if f.kind == .poi, let n = f.name, let p = gpts.first { poiList.append((n, p)) }
            }
        }
        features = FeatureField(originLat: oLat, originLon: oLon, features: allFeats)
        trails = trailSegs.isEmpty ? nil : RoadIndex(segments: trailSegs)
        pois = poiList
    }

    /// Load + merge every downloaded patch (heavy decode off the main thread).
    static func build() async -> Atlas? {
        AtlasStore.migrateLegacyIfNeeded()
        let patches = AtlasStore.patches()
        guard !patches.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> Atlas? in
            var graphs: [RoadGraph] = [], dems: [(AreaPatch, TerrariumDEM)] = [], feats: [(AreaPatch, FeatureField)] = []
            for p in patches {
                if let g = AtlasStore.loadGraph(p.id) { graphs.append(g) }
                if let d = AtlasStore.loadDEM(p.id) { dems.append((p, d)) }
                if let f = AtlasStore.loadFeatures(p.id) { feats.append((p, f)) }
            }
            guard !graphs.isEmpty || !dems.isEmpty else { return nil }
            return Atlas(patches: patches, graphs: graphs, dems: dems, feats: feats)
        }.value
    }
}
