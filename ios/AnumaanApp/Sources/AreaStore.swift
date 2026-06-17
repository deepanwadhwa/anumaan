import Foundation
import CoreLocation
import AnumaanCore

/// Tiny manifest in area.json; the heavy layers live in their own files and load
/// lazily, so area.json stays kilobytes and no big blob is decoded on the main
/// thread.
///   area.json     — name + center + which layers exist (kilobytes)
///   graph.json    — road graph snapshot (routing; moderate)
///   dem.bin       — elevation, compact binary (heavy, lazy)
///   features.bin  — map features, compact binary (heavy, lazy)
struct AreaManifest: Codable {
    let name: String
    let lat: Double
    let lon: Double
    let hasDEM: Bool
    let hasFeatures: Bool
}

enum AreaStore {
    private static func doc(_ name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }
    private static var manifestURL: URL { doc("area.json") }
    private static var graphURL: URL    { doc("graph.json") }
    private static var demURL: URL      { doc("dem.bin") }
    private static var featURL: URL     { doc("features.bin") }

    private static let lock = NSLock()
    private static var graphCache: RoadGraph?
    private static var demCache: TerrariumDEM?
    private static var featCache: FeatureField?

    static func save(name: String, center: CLLocationCoordinate2D, graph: RoadGraph,
                     dem: TerrariumDEM? = nil, features: FeatureField? = nil) {
        let manifest = AreaManifest(name: name, lat: center.latitude, lon: center.longitude,
                                    hasDEM: dem != nil, hasFeatures: features != nil)
        if let d = try? JSONEncoder().encode(manifest) { try? d.write(to: manifestURL, options: .atomic) }
        if let d = try? JSONEncoder().encode(graph.snapshot()) { try? d.write(to: graphURL, options: .atomic) }
        if let dem { try? dem.encodedBinary().write(to: demURL, options: .atomic) }
        else { try? FileManager.default.removeItem(at: demURL) }
        if let features { try? features.encodedBinary().write(to: featURL, options: .atomic) }
        else { try? FileManager.default.removeItem(at: featURL) }
        lock.lock(); graphCache = graph; demCache = dem; featCache = features; lock.unlock()
    }

    static func loadManifest() -> AreaManifest? {
        guard let d = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(AreaManifest.self, from: d)
    }

    static func loadGraph() -> RoadGraph? {
        lock.lock(); if let c = graphCache { lock.unlock(); return c }; lock.unlock()
        guard let d = try? Data(contentsOf: graphURL),
              let snap = try? JSONDecoder().decode(RoadGraph.Snapshot.self, from: d) else { return nil }
        let g = RoadGraph.restore(snap)
        lock.lock(); graphCache = g; lock.unlock()
        return g
    }

    static func loadDEM() -> TerrariumDEM? {
        lock.lock(); if let c = demCache { lock.unlock(); return c }; lock.unlock()
        guard let d = try? Data(contentsOf: demURL), let dem = TerrariumDEM.decodeBinary(d) else { return nil }
        lock.lock(); demCache = dem; lock.unlock()
        return dem
    }

    static func loadFeatures() -> FeatureField? {
        lock.lock(); if let c = featCache { lock.unlock(); return c }; lock.unlock()
        guard let d = try? Data(contentsOf: featURL), let ff = FeatureField.decodeBinary(d) else { return nil }
        lock.lock(); featCache = ff; lock.unlock()
        return ff
    }

    static func clear() {
        for u in [manifestURL, graphURL, demURL, featURL] { try? FileManager.default.removeItem(at: u) }
        lock.lock(); graphCache = nil; demCache = nil; featCache = nil; lock.unlock()
    }
}
