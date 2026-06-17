import Foundation
import CoreLocation
import AnumaanCore

/// One downloaded chunk of offline map (bbox + its own DEM / features / road
/// graph). Downloads ACCUMULATE into a collection of these, so a big area like a
/// national park can be covered by several downloads over time.
struct AreaPatch: Codable, Identifiable {
    let id: String
    let name: String
    let south, west, north, east: Double
    let lat, lon: Double            // center
    let hasDEM, hasFeatures: Bool
}

/// Persists the patch collection. Each patch lives in atlas/<id>/, and atlas/
/// index.json lists them. Heavy layers are the compact binaries.
enum AtlasStore {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("atlas", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var indexURL: URL { dir.appendingPathComponent("index.json") }
    private static func patchDir(_ id: String) -> URL {
        let d = dir.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static let lock = NSLock()

    static func patches() -> [AreaPatch] {
        guard let d = try? Data(contentsOf: indexURL),
              let p = try? JSONDecoder().decode([AreaPatch].self, from: d) else { return [] }
        return p
    }

    @discardableResult
    static func addPatch(name: String, south: Double, west: Double, north: Double, east: Double,
                         center: CLLocationCoordinate2D, graph: RoadGraph,
                         dem: TerrariumDEM?, features: FeatureField?) -> AreaPatch {
        let id = UUID().uuidString
        let d = patchDir(id)
        if let data = try? JSONEncoder().encode(graph.snapshot()) {
            try? data.write(to: d.appendingPathComponent("graph.json"), options: .atomic)
        }
        if let dem { try? dem.encodedBinary().write(to: d.appendingPathComponent("dem.bin"), options: .atomic) }
        if let features { try? features.encodedBinary().write(to: d.appendingPathComponent("features.bin"), options: .atomic) }
        let patch = AreaPatch(id: id, name: name, south: south, west: west, north: north, east: east,
                              lat: center.latitude, lon: center.longitude,
                              hasDEM: dem != nil, hasFeatures: features != nil)
        lock.lock(); var all = patches(); all.append(patch)
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: indexURL, options: .atomic) }
        lock.unlock()
        return patch
    }

    static func loadGraph(_ id: String) -> RoadGraph? {
        guard let d = try? Data(contentsOf: patchDir(id).appendingPathComponent("graph.json")),
              let s = try? JSONDecoder().decode(RoadGraph.Snapshot.self, from: d) else { return nil }
        return RoadGraph.restore(s)
    }
    static func loadDEM(_ id: String) -> TerrariumDEM? {
        guard let d = try? Data(contentsOf: patchDir(id).appendingPathComponent("dem.bin")) else { return nil }
        return TerrariumDEM.decodeBinary(d)
    }
    static func loadFeatures(_ id: String) -> FeatureField? {
        guard let d = try? Data(contentsOf: patchDir(id).appendingPathComponent("features.bin")) else { return nil }
        return FeatureField.decodeBinary(d)
    }

    /// One-time import of a legacy single-area download (old AreaStore) into the
    /// patch collection, so existing offline maps survive the multi-area upgrade.
    static func migrateLegacyIfNeeded() {
        guard patches().isEmpty, let m = AreaStore.loadManifest() else { return }
        let g = AreaStore.loadGraph() ?? RoadGraph()
        let dem = AreaStore.loadDEM()
        let feats = AreaStore.loadFeatures()
        var s = m.lat - 0.02, w = m.lon - 0.02, n = m.lat + 0.02, e = m.lon + 0.02
        if let dem {                                  // recover the bbox from the DEM's pixel extent
            let mPerPx = 156_543.03392 * cos(dem.originLat * .pi / 180) / pow(2, Double(dem.z))
            let halfW = Double(dem.width) / 2 * mPerPx, halfH = Double(dem.height) / 2 * mPerPx
            let sw = dem.latLon(x: -halfW, y: -halfH), ne = dem.latLon(x: halfW, y: halfH)
            s = sw.lat; w = sw.lon; n = ne.lat; e = ne.lon
        }
        addPatch(name: m.name, south: s, west: w, north: n, east: e,
                 center: .init(latitude: m.lat, longitude: m.lon), graph: g, dem: dem, features: feats)
        AreaStore.clear()                              // migrated — don't re-import
    }

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(at: patchDir(id))
        lock.lock(); let all = patches().filter { $0.id != id }
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: indexURL, options: .atomic) }
        lock.unlock()
    }
    static func clearAll() {
        try? FileManager.default.removeItem(at: dir)
    }
}
