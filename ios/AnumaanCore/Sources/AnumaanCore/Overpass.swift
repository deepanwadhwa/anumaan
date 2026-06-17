import Foundation

/// Builds a `RoadGraph` from an Overpass API JSON response (the iOS layer does
/// the actual `URLSession` download; this pure parse is unit-testable). Mirrors
/// the graph-building that `osmnx` did in the Python prototype.
public enum Overpass {

    /// Overpass query for the drivable network in a bbox (south,west,north,east).
    public static func query(south: Double, west: Double, north: Double, east: Double) -> String {
        let cls = "motorway|trunk|primary|secondary|tertiary|residential|unclassified|living_street|service"
        return """
        [out:json][timeout:60];
        way["highway"~"\(cls)"](\(south),\(west),\(north),\(east));
        (._;>;);
        out body;
        """
    }

    /// Overpass query for the full walkable network — roads + footways/paths/trails.
    /// Use this when the user may be walking in parks, gardens, or anywhere off the
    /// drivable road network.
    public static func walkingQuery(south: Double, west: Double, north: Double, east: Double) -> String {
        let cls = "motorway|trunk|primary|secondary|tertiary|residential|unclassified|living_street|service|footway|path|track|pedestrian|cycleway|steps"
        return """
        [out:json][timeout:60];
        way["highway"~"\(cls)"](\(south),\(west),\(north),\(east));
        (._;>;);
        out body;
        """
    }

    // Fallback speeds (m/s) by highway class when maxspeed is missing.
    static let defaultSpeeds: [String: Double] = [
        "motorway": 31, "trunk": 27, "primary": 18, "secondary": 15, "tertiary": 13,
        "residential": 11, "living_street": 7, "service": 7, "unclassified": 11,
        "footway": 1.4, "path": 1.4, "track": 1.4, "pedestrian": 1.4,
        "cycleway": 1.4, "steps": 0.8,
    ]

    static func parseSpeed(_ maxspeed: String?, highway: String?) -> Double {
        if let ms = maxspeed,
           let m = ms.range(of: #"\d+(\.\d+)?"#, options: .regularExpression),
           let v = Double(ms[m]) {
            return ms.lowercased().contains("mph") ? v * 0.44704 : v / 3.6
        }
        return defaultSpeeds[highway ?? ""] ?? 11
    }

    private struct Response: Decodable { let elements: [Element] }
    private struct Element: Decodable {
        let type: String
        let id: Int
        let lat: Double?
        let lon: Double?
        let nodes: [Int]?
        let tags: [String: String]?
    }

    /// Parse Overpass JSON into a routable graph (one-ways respected).
    public static func buildGraph(from data: Data) throws -> RoadGraph {
        let resp = try JSONDecoder().decode(Response.self, from: data)
        let graph = RoadGraph()

        // Pass 1: node coordinates + types (stop signs, traffic lights, …).
        var coord: [Int: (Double, Double)] = [:]
        var ntype: [Int: String] = [:]
        for e in resp.elements where e.type == "node" {
            if let la = e.lat, let lo = e.lon { coord[e.id] = (la, lo) }
            if let hw = e.tags?["highway"] { ntype[e.id] = classifyNode(hw) }
        }
        // Pass 2: ways → edges (only add nodes a way actually uses).
        for e in resp.elements where e.type == "way" {
            guard let ids = e.nodes, let tags = e.tags, tags["highway"] != nil else { continue }
            let hw = tags["highway"] ?? ""
            let defaultName = ["footway","path","track","pedestrian","cycleway","steps"].contains(hw)
                ? "unnamed path" : "unnamed road"
            let name = tags["name"] ?? tags["ref"] ?? defaultName
            let speed = parseSpeed(tags["maxspeed"], highway: tags["highway"])
            let oneway = ["yes", "true", "1"].contains(tags["oneway"] ?? "")
            for (a, b) in zip(ids, ids.dropFirst()) {
                guard let ca = coord[a], let cb = coord[b] else { continue }
                graph.addNode(String(a), lat: ca.0, lon: ca.1, type: ntype[a] ?? "intersection")
                graph.addNode(String(b), lat: cb.0, lon: cb.1, type: ntype[b] ?? "intersection")
                graph.addEdge(String(a), String(b), name: name, speed: speed, oneway: oneway)
            }
        }
        return graph
    }

    static func classifyNode(_ highway: String) -> String {
        let h = highway.lowercased()
        if h.contains("stop") { return "stop_sign" }
        if h.contains("traffic_signals") || h.contains("signal") { return "traffic_light" }
        if h.contains("crossing") { return "crossing" }
        if h.contains("mini_roundabout") || h.contains("roundabout") { return "roundabout" }
        return "intersection"
    }
}
