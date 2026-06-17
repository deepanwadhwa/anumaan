import Foundation

/// A drivable road graph + A* routing + conversion to the engine's milestone
/// array (port of the routing half of `app/routing.py`). Pure Swift so it
/// compiles and tests from the CLI; the iOS layer fills it from an Overpass
/// download and feeds the resulting `Route` to MapLibre + the engine.
public final class RoadGraph {
    public struct Node: Codable {
        public let id: String; public let lat: Double; public let lon: Double
        public let type: String   // "stop_sign" | "traffic_light" | "crossing" | "intersection"
    }
    public struct Edge {
        public let to: String
        public let lengthM: Double
        public let name: String
        public let speed: Double      // m/s
    }

    public private(set) var nodes: [String: Node] = [:]
    private var adj: [String: [Edge]] = [:]

    public init() {}

    public func addNode(_ id: String, lat: Double, lon: Double, type: String = "intersection") {
        // Don't downgrade a known type (e.g. stop sign) back to plain intersection.
        if let existing = nodes[id], existing.type != "intersection", type == "intersection" { return }
        nodes[id] = Node(id: id, lat: lat, lon: lon, type: type)
        if adj[id] == nil { adj[id] = [] }
    }

    // MARK: persistence (save a downloaded area to disk, reload on launch)
    public struct Snapshot: Codable {
        public let nodes: [Node]
        public let edges: [DirectedEdge]
    }
    public struct DirectedEdge: Codable {
        public let from, to, name: String; public let speed: Double
    }
    public func snapshot() -> Snapshot {
        var edges: [DirectedEdge] = []
        for (from, list) in adj {
            for e in list { edges.append(.init(from: from, to: e.to, name: e.name, speed: e.speed)) }
        }
        return Snapshot(nodes: Array(nodes.values), edges: edges)
    }
    public static func restore(_ s: Snapshot) -> RoadGraph {
        let g = RoadGraph()
        for n in s.nodes { g.addNode(n.id, lat: n.lat, lon: n.lon, type: n.type) }
        for e in s.edges { g.addEdge(e.from, e.to, name: e.name, speed: e.speed, oneway: true) }
        return g
    }

    /// Add a road segment. `oneway` adds only the forward direction.
    public func addEdge(_ a: String, _ b: String, name: String = "road",
                        speed: Double = 11, oneway: Bool = false) {
        guard let na = nodes[a], let nb = nodes[b] else { return }
        let len = Turn.haversine((na.lat, na.lon), (nb.lat, nb.lon))
        adj[a, default: []].append(Edge(to: b, lengthM: len, name: name, speed: speed))
        if !oneway {
            adj[b, default: []].append(Edge(to: a, lengthM: len, name: name, speed: speed))
        }
    }

    public func nearestNode(lat: Double, lon: Double) -> String? {
        var best: String?
        var bestD = Double.greatestFiniteMagnitude
        for (id, n) in nodes {
            let d = Turn.haversine((lat, lon), (n.lat, n.lon))
            if d < bestD { bestD = d; best = id }
        }
        return best
    }

    /// A* shortest path by edge length (haversine heuristic). Returns node ids.
    public func shortestPath(from: String, to: String) -> [String]? {
        guard let goal = nodes[to] else { return nil }
        func h(_ id: String) -> Double {
            guard let n = nodes[id] else { return 0 }
            return Turn.haversine((n.lat, n.lon), (goal.lat, goal.lon))
        }
        var g: [String: Double] = [from: 0]
        var came: [String: String] = [:]
        var open = Heap(); open.push(from, h(from))
        var closed = Set<String>()
        while let cur = open.pop() {
            if cur == to { return reconstruct(came, to) }
            if closed.contains(cur) { continue }
            closed.insert(cur)
            for e in adj[cur] ?? [] {
                let ng = (g[cur] ?? .greatestFiniteMagnitude) + e.lengthM
                if ng < (g[e.to] ?? .greatestFiniteMagnitude) {
                    g[e.to] = ng; came[e.to] = cur
                    open.push(e.to, ng + h(e.to))
                }
            }
        }
        return nil
    }

    private func reconstruct(_ came: [String: String], _ end: String) -> [String] {
        var path = [end]
        while let p = came[path.last!] { path.append(p) }
        return path.reversed()
    }

    private func edge(_ a: String, _ b: String) -> Edge? {
        (adj[a] ?? []).first { $0.to == b }
    }

    /// Number of distinct road neighbours (2 ⇒ a mid-road geometry point).
    public func degree(_ id: String) -> Int { Set((adj[id] ?? []).map { $0.to }).count }

    /// Turn a node path into a drawable + drivable `Route`. The drawn polyline
    /// follows every node (geometry), but **milestones are only real decision
    /// points** — intersections, stop signs, lights, and the endpoints. Plain
    /// degree-2 geometry nodes are collapsed into the leg.
    public func buildRoute(path: [String]) -> Route {
        var coords: [[Double]] = []
        var milestones: [Milestone] = []
        var routeNodes: [RouteNode] = []
        var total = 0.0
        var legDist = 0.0
        var legStreet = "road"

        guard let first = nodes[path.first ?? ""] else {
            return Route(coords: [], milestones: [], nodes: [], totalDistanceM: 0, estTimeS: 0)
        }
        coords.append([first.lat, first.lon])
        milestones.append(Milestone(id: first.id, type: "origin", distanceFromPrior: 0, name: "Start"))
        routeNodes.append(RouteNode(id: first.id, lat: first.lat, lon: first.lon, cumulativeM: 0))
        var prevMile = (lat: first.lat, lon: first.lon)

        for i in 1..<path.count {
            let a = path[i - 1], b = path[i]
            guard let nb = nodes[b], let e = edge(a, b) else { continue }
            total += e.lengthM
            legDist += e.lengthM
            legStreet = e.name
            coords.append([nb.lat, nb.lon])
            let isLast = i == path.count - 1
            let isDecision = isLast || nb.type != "intersection" || degree(b) != 2
            if isDecision {
                let straight = Turn.haversine(prevMile, (nb.lat, nb.lon))
                milestones.append(Milestone(id: b, type: isLast ? "destination" : nb.type,
                                            distanceFromPrior: legDist,
                                            name: isLast ? "Destination" : legStreet,
                                            targetSpeedLimit: e.speed))
                routeNodes.append(RouteNode(id: b, lat: nb.lat, lon: nb.lon, cumulativeM: total,
                                            legBearing: (Turn.bearing(prevMile, (nb.lat, nb.lon)) * 10).rounded() / 10,
                                            legStraight: legDist >= 40 && legDist <= 1.2 * max(straight, 1)))
                prevMile = (nb.lat, nb.lon)
                legDist = 0
            }
        }

        // Expected turn at each intermediate milestone.
        for i in routeNodes.indices where i > 0 && i < routeNodes.count - 1 {
            let p = (routeNodes[i - 1].lat, routeNodes[i - 1].lon)
            let n = (routeNodes[i].lat, routeNodes[i].lon)
            let q = (routeNodes[i + 1].lat, routeNodes[i + 1].lon)
            let ang = Turn.turnAngle(prev: p, node: n, next: q)
            routeNodes[i] = RouteNode(id: routeNodes[i].id, lat: n.0, lon: n.1,
                                      cumulativeM: routeNodes[i].cumulativeM,
                                      turnAngle: (ang * 10).rounded() / 10,
                                      turnLabel: Turn.classify(ang),
                                      legBearing: routeNodes[i].legBearing,
                                      legStraight: routeNodes[i].legStraight)
        }

        let avg = milestones.dropFirst().map(\.targetSpeedLimit).reduce(0, +)
            / Double(max(milestones.count - 1, 1))
        return Route(coords: coords, milestones: milestones, nodes: routeNodes,
                     totalDistanceM: total, estTimeS: total / max(avg, 1))
    }
}

/// Tiny binary heap keyed by priority (min-first) for A*.
struct Heap {
    private var items: [(String, Double)] = []
    var isEmpty: Bool { items.isEmpty }
    mutating func push(_ id: String, _ priority: Double) {
        items.append((id, priority)); siftUp(items.count - 1)
    }
    mutating func pop() -> String? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let (id, _) = items.removeLast()
        if !items.isEmpty { siftDown(0) }
        return id
    }
    private mutating func siftUp(_ i: Int) {
        var c = i
        while c > 0 {
            let p = (c - 1) / 2
            if items[c].1 < items[p].1 { items.swapAt(c, p); c = p } else { break }
        }
    }
    private mutating func siftDown(_ i: Int) {
        var p = i
        let n = items.count
        while true {
            let l = 2 * p + 1, r = 2 * p + 2
            var s = p
            if l < n && items[l].1 < items[s].1 { s = l }
            if r < n && items[r].1 < items[s].1 { s = r }
            if s == p { break }
            items.swapAt(p, s); p = s
        }
    }
}
