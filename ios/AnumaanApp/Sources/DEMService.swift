import Foundation
import UIKit
import AnumaanCore

/// Downloads offline elevation for a bbox from AWS Open Data's Mapzen/Terrarium
/// tiles — public, no key, plain HTTPS (`--no-sign-request` is only needed for
/// the S3 *API*; the `s3.amazonaws.com/.../{z}/{x}/{y}.png` URLs are open). Tiles
/// are decoded (RGB→meters) and stitched into a `TerrariumDEM` for the recovery
/// engine. Honors the "don't download everything" rule with a hard tile cap.
enum DEMService {
    static let host = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium"
    static let maxTiles = 90          // ~6 MB of raster; keeps survival downloads sane
    static let zoomRange = 8...13     // 30 m detail lives around z12–13

    enum DEMError: LocalizedError {
        case tooBig(Int), http(Int), decode
        var errorDescription: String? {
            switch self {
            case .tooBig(let n): return "Elevation area too large (\(n) tiles) — frame a smaller region."
            case .http(let c):   return "Elevation tile server returned HTTP \(c)"
            case .decode:        return "Couldn't decode an elevation tile"
            }
        }
    }

    /// Highest zoom in `zoomRange` whose tile count fits under `maxTiles`.
    static func chooseZoom(south: Double, west: Double, north: Double, east: Double) -> Int? {
        for z in zoomRange.reversed() {
            if TileMath.tiles(south: south, west: west, north: north, east: east, z: z).count <= maxTiles {
                return z
            }
        }
        return nil
    }

    static func download(south: Double, west: Double, north: Double, east: Double,
                         centerLat: Double, centerLon: Double) async throws -> TerrariumDEM {
        guard let z = chooseZoom(south: south, west: west, north: north, east: east) else {
            let n = TileMath.tiles(south: south, west: west, north: north, east: east, z: zoomRange.lowerBound).count
            throw DEMError.tooBig(n)
        }
        let r = TileMath.tileRange(south: south, west: west, north: north, east: east, z: z)
        let cols = r.xMax - r.xMin + 1, rows = r.yMax - r.yMin + 1
        let width = cols * 256, height = rows * 256
        var elev = [Int16](repeating: 0, count: width * height)

        // Fetch + decode tiles concurrently, each writing into its slice of the raster.
        try await withThrowingTaskGroup(of: (Int, Int, [Int16]).self) { group in
            for ty in r.yMin...r.yMax {
                for tx in r.xMin...r.xMax {
                    group.addTask {
                        let px = try await fetchTile(z: z, x: tx, y: ty)
                        return (tx - r.xMin, ty - r.yMin, px)
                    }
                }
            }
            for try await (col, row, px) in group {
                let ox = col * 256, oy = row * 256
                for ry in 0..<256 {
                    let dst = (oy + ry) * width + ox
                    let src = ry * 256
                    for cx in 0..<256 { elev[dst + cx] = px[src + cx] }
                }
            }
        }

        return TerrariumDEM(z: z, px0: r.xMin * 256, py0: r.yMin * 256,
                            width: width, height: height, elev: elev,
                            originLat: centerLat, originLon: centerLon)
    }

    /// Download one tile and decode its 256×256 RGB pixels to Int16 meters.
    private static func fetchTile(z: Int, x: Int, y: Int) async throws -> [Int16] {
        let url = URL(string: "\(host)/\(z)/\(x)/\(y).png")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw DEMError.http(code) }
        guard let img = UIImage(data: data)?.cgImage else { throw DEMError.decode }

        let w = 256, h = 256
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw DEMError.decode
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

        var out = [Int16](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let p = i * 4
            let m = Terrarium.elevation(r: rgba[p], g: rgba[p + 1], b: rgba[p + 2])
            out[i] = Int16(max(-32768, min(32767, m.rounded())))
        }
        return out
    }
}
