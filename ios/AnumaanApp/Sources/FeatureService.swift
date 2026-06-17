import Foundation
import AnumaanCore

/// Downloads hiker-relevant map features (water, streams, woods, meadows, peaks)
/// by fetching the SAME OpenFreeMap vector tiles the basemap uses and decoding
/// them on-device — so we never touch Overpass. Builds a compact `FeatureField`.
enum FeatureService {
    static let tileJSONURL = "https://tiles.openfreemap.org/planet"
    static let zoomRange = 10...14          // OpenFreeMap vector maxzoom is 14
    static let maxTiles = 80

    enum FeatureError: LocalizedError {
        case tooBig(Int), noTemplate
        var errorDescription: String? {
            switch self {
            case .tooBig(let n): return "Feature area too large (\(n) tiles)"
            case .noTemplate:    return "Couldn't read the tile template"
            }
        }
    }

    static func chooseZoom(south: Double, west: Double, north: Double, east: Double) -> Int? {
        for z in zoomRange.reversed() where
            TileMath.tiles(south: south, west: west, north: north, east: east, z: z).count <= maxTiles {
            return z
        }
        return nil
    }

    /// Read the current dated tile-URL template from the TileJSON (it changes as
    /// OpenFreeMap re-publishes the planet).
    private static func tileTemplate() async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: URL(string: tileJSONURL)!)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tiles = obj["tiles"] as? [String], let t = tiles.first else { throw FeatureError.noTemplate }
        return t
    }

    static func download(south: Double, west: Double, north: Double, east: Double,
                         centerLat: Double, centerLon: Double) async throws -> FeatureField {
        guard let z = chooseZoom(south: south, west: west, north: north, east: east) else {
            throw FeatureError.tooBig(TileMath.tiles(south: south, west: west, north: north,
                                                     east: east, z: zoomRange.lowerBound).count)
        }
        let template = try await tileTemplate()
        let r = TileMath.tileRange(south: south, west: west, north: north, east: east, z: z)

        var decoded: [(tile: MVT.Tile, z: Int, x: Int, y: Int)] = []
        await withTaskGroup(of: (MVT.Tile, Int, Int, Int)?.self) { group in
            for ty in r.yMin...r.yMax {
                for tx in r.xMin...r.xMax {
                    group.addTask {
                        let urlStr = template
                            .replacingOccurrences(of: "{z}", with: "\(z)")
                            .replacingOccurrences(of: "{x}", with: "\(tx)")
                            .replacingOccurrences(of: "{y}", with: "\(ty)")
                        guard let url = URL(string: urlStr),
                              let (data, resp) = try? await URLSession.shared.data(from: url),
                              (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty,
                              let tile = try? MVT.decode(data) else { return nil }
                        return (tile, z, tx, ty)
                    }
                }
            }
            for await item in group { if let i = item { decoded.append((i.0, i.1, i.2, i.3)) } }
        }
        return FeatureField.fromMVT(tiles: decoded, originLat: centerLat, originLon: centerLon)
    }
}
