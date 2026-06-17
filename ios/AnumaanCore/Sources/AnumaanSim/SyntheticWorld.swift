import Foundation
import AnumaanCore

/// A fully self-contained, deterministic demo: a 5x5 grid of named streets over a
/// gently rolling synthetic DEM, with a known walk that ends at the Creekway Road
/// & Oak Avenue intersection. No network. Doubles as a fast regression check.
func runSyntheticDemo() {
    let spacingM = 100.0, cols = 5, rows = 5
    func idx(_ c: Int, _ r: Int) -> Int { c * rows + r }
    func pos(_ c: Int, _ r: Int) -> GeoPoint { GeoPoint(x: Double(c) * spacingM, y: Double(r) * spacingM) }

    var nodes: [GeoPoint] = []
    for c in 0..<cols { for r in 0..<rows { nodes.append(pos(c, r)) } }
    var adj = [[Int]](repeating: [], count: nodes.count)
    func link(_ a: Int, _ b: Int) {
        if !adj[a].contains(b) { adj[a].append(b) }
        if !adj[b].contains(a) { adj[b].append(a) }
    }
    for c in 0..<cols { for r in 0..<rows {
        if c + 1 < cols { link(idx(c, r), idx(c + 1, r)) }
        if r + 1 < rows { link(idx(c, r), idx(c, r + 1)) }
    }}

    let colName = ["West Street", "Pine Street", "Creekway Road", "Maple Street", "East Street"]
    let rowName = ["1st Avenue", "2nd Avenue", "Oak Avenue", "3rd Avenue", "4th Avenue"]
    var namedRoads: [String: [(GeoPoint, GeoPoint)]] = [:]
    for c in 0..<cols { for r in 0..<rows {
        if r + 1 < rows { namedRoads[colName[c], default: []].append((pos(c, r), pos(c, r + 1))) }
        if c + 1 < cols { namedRoads[rowName[r], default: []].append((pos(c, r), pos(c + 1, r))) }
    }}
    var landmarks: [(p: GeoPoint, kind: String)] = []
    for i in nodes.indices where adj[i].count >= 3 { landmarks.append((p: nodes[i], kind: "intersection")) }

    func elevAt(_ p: GeoPoint) -> Double {
        8 * sin((0.6 * p.x + 1.3 * p.y) / 100) + 5 * cos((1.1 * p.x - 0.7 * p.y) / 100) + 0.01 * p.x
    }
    let demCell = 20.0, demOX = -100.0, demOY = -100.0, demCols = 36, demRows = 36
    var heights = [Double](repeating: 0, count: demCols * demRows)
    for r in 0..<demRows { for c in 0..<demCols {
        heights[r * demCols + c] = elevAt(GeoPoint(x: demOX + Double(c) * demCell, y: demOY + Double(r) * demCell))
    }}
    let dem = GridDEM(cols: demCols, rows: demRows, cellSize: demCell, originX: demOX, originY: demOY, heights: heights)

    let features = FeatureField(originLat: 0, originLon: 0, features: [
        MapFeature(kind: .waterway, isArea: false,
                   points: [GeoPoint(x: 400, y: 0), GeoPoint(x: 400, y: 400)], name: "East Creek"),
        MapFeature(kind: .wood, isArea: true,
                   points: [GeoPoint(x: -60, y: 300), GeoPoint(x: 60, y: 300),
                            GeoPoint(x: 60, y: 430), GeoPoint(x: -60, y: 430)], name: nil),
    ])

    let truePoly = [idx(1, 0), idx(2, 0), idx(2, 1), idx(2, 2)].map { nodes[$0] }   // E then N N
    let trueEnd = truePoly.last!                                                    // Creekway & Oak
    let stepM = 15.0
    var rng = LCG(seed: 0xC0FFEE)
    let walk = synthesizeWalk(poly: truePoly, stepM: stepM, headingNoiseDeg: 3, baroNoiseM: 0.3,
                              elevation: elevAt, rng: &rng)
    let matcher = runMatcher(nodes: nodes, adjacency: adj, dem: dem,
                             headings: walk.headings, cumElev: walk.cumElev, stepM: stepM, seeds: 5000)

    print("=== AnumaanSim — synthetic road-walk recovery ===")
    print("World: 5x5 grid, 100 m spacing. Truth ends at Creekway Road & Oak Avenue (x=\(Int(trueEnd.x)), y=\(Int(trueEnd.y))).")
    print("Walk: E 100 m then N 200 m (1 turn), \(walk.headings.count) bins of \(Int(stepM)) m, heading noise σ=3°.")
    let map = InterrogationMap(features: features, dem: dem, landmarks: landmarks,
                               namedRoads: namedRoads.map { (name: $0.key, segments: $0.value) }, pois: [])
    runInterrogation(matcher: matcher, map: map, trueEnd: trueEnd, heading: walk.headings.last)
}
