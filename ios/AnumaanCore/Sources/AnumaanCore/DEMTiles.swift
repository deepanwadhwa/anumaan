import Foundation

/// Slippy-map (XYZ / web-Mercator) tile math, shared by the road basemap and the
/// elevation tiles. Tiles are 256 px; the world at zoom z is `256·2^z` px wide.
public enum TileMath {
    public static func worldPixels(_ z: Int) -> Double { Double(256 * (1 << z)) }

    public static func globalPixelX(lon: Double, z: Int) -> Double {
        (lon + 180) / 360 * worldPixels(z)
    }
    public static func globalPixelY(lat: Double, z: Int) -> Double {
        let r = lat * .pi / 180
        return (1 - asinh(tan(r)) / .pi) / 2 * worldPixels(z)
    }
    public static func tileX(lon: Double, z: Int) -> Int {
        Int((globalPixelX(lon: lon, z: z) / 256).rounded(.down))
    }
    public static func tileY(lat: Double, z: Int) -> Int {
        Int((globalPixelY(lat: lat, z: z) / 256).rounded(.down))
    }

    /// Inclusive XYZ tile range covering a bbox. Note y grows southward, so
    /// `north` gives the smaller y.
    public static func tileRange(south: Double, west: Double, north: Double, east: Double,
                                 z: Int) -> (xMin: Int, xMax: Int, yMin: Int, yMax: Int) {
        let n = 1 << z
        func clamp(_ v: Int) -> Int { Swift.max(0, Swift.min(n - 1, v)) }
        return (clamp(tileX(lon: west, z: z)), clamp(tileX(lon: east, z: z)),
                clamp(tileY(lat: north, z: z)), clamp(tileY(lat: south, z: z)))
    }

    /// Tile-local coordinate (0…extent) within tile (z,x,y) → lon/lat. Used to
    /// turn decoded MVT geometry into geographic coordinates.
    public static func tileToLonLat(z: Int, x: Int, y: Int, tx: Double, ty: Double,
                                    extent: Double) -> (lon: Double, lat: Double) {
        let n = Double(1 << z)
        let fx = (Double(x) + tx / extent) / n
        let fy = (Double(y) + ty / extent) / n
        return (fx * 360 - 180, atan(sinh(.pi * (1 - 2 * fy))) * 180 / .pi)
    }

    public static func tiles(south: Double, west: Double, north: Double, east: Double,
                             z: Int) -> [(x: Int, y: Int)] {
        let r = tileRange(south: south, west: west, north: north, east: east, z: z)
        var out: [(Int, Int)] = []
        for y in r.yMin...r.yMax { for x in r.xMin...r.xMax { out.append((x, y)) } }
        return out
    }
}

/// Terrarium RGB-encoded elevation: each pixel packs meters as
/// `(R·256 + G + B/256) − 32768`. (Mapzen/AWS `elevation-tiles-prod` format.)
public enum Terrarium {
    public static func elevation(r: UInt8, g: UInt8, b: UInt8) -> Double {
        (Double(r) * 256 + Double(g) + Double(b) / 256) - 32768
    }
}

/// A `DEMProvider` backed by a stitched raster of Terrarium tiles (meters,
/// rounded to `Int16`). Works in the recovery engine's local-meter frame: it
/// converts a local (east, north) point back to lat/lon (equirectangular around
/// `origin`, fine for a survival-radius region), then bilinearly samples the
/// web-Mercator pixel raster. `Codable`, so it persists offline with the area.
public struct TerrariumDEM: DEMProvider, Codable {
    public let z: Int
    public let px0: Int           // global pixel x of the raster's left edge
    public let py0: Int           // global pixel y of the raster's top edge
    public let width: Int
    public let height: Int
    public let elev: [Int16]      // row-major, height×width, meters
    public let originLat: Double  // local-meter frame origin (x=0,y=0)
    public let originLon: Double

    public init(z: Int, px0: Int, py0: Int, width: Int, height: Int, elev: [Int16],
                originLat: Double, originLon: Double) {
        self.z = z; self.px0 = px0; self.py0 = py0
        self.width = width; self.height = height; self.elev = elev
        self.originLat = originLat; self.originLon = originLon
    }

    private static let metersPerDegLat = 111_320.0

    /// Local meters (E,N) from origin → lat/lon.
    public func latLon(x: Double, y: Double) -> (lat: Double, lon: Double) {
        let lat = originLat + y / Self.metersPerDegLat
        let lon = originLon + x / (Self.metersPerDegLat * cos(originLat * .pi / 180))
        return (lat, lon)
    }
    /// lat/lon → local meters (E,N) from origin (inverse of `latLon`).
    public func meters(lat: Double, lon: Double) -> GeoPoint {
        GeoPoint(x: (lon - originLon) * Self.metersPerDegLat * cos(originLat * .pi / 180),
                 y: (lat - originLat) * Self.metersPerDegLat)
    }

    public func elevation(x: Double, y: Double) -> Double? {
        let ll = latLon(x: x, y: y)
        let fx = TileMath.globalPixelX(lon: ll.lon, z: z) - Double(px0)
        let fy = TileMath.globalPixelY(lat: ll.lat, z: z) - Double(py0)
        if fx < 0 || fy < 0 || fx > Double(width - 1) || fy > Double(height - 1) { return nil }
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        let v00 = Double(elev[y0 * width + x0]), v10 = Double(elev[y0 * width + x1])
        let v01 = Double(elev[y1 * width + x0]), v11 = Double(elev[y1 * width + x1])
        let a = v00 + (v10 - v00) * tx
        let b = v01 + (v11 - v01) * tx
        return a + (b - a) * ty
    }
}
