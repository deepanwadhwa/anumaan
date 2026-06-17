import Foundation

/// A point in a local planar frame, meters. x = easting (+E), y = northing (+N).
/// The wilderness engine works in meters so heading geometry stays simple; the
/// iOS layer maps lat/lon ⇆ this local frame around the search center.
public struct GeoPoint: Equatable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public func distance(to o: GeoPoint) -> Double {
        ((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y)).squareRoot()
    }
}

/// Anything that can return ground elevation (m) at a planar point. Backed by a
/// synthetic grid in tests; by a real 30 m DEM tile on device.
public protocol DEMProvider {
    func elevation(x: Double, y: Double) -> Double?
}

public extension DEMProvider {
    /// Sample a **relative** elevation profile (each sample minus the first) while
    /// walking `length` m from `start` along `headingDeg` (0 = north/+y, 90 =
    /// east/+x), one sample every `step` m. Relative, because the barometer only
    /// gives elevation *change*. Stops early if the walk leaves the map.
    func profile(from start: GeoPoint, headingDeg: Double, length: Double, step: Double) -> [Double] {
        let n = max(1, Int((length / step).rounded()))
        let rad = headingDeg * .pi / 180
        let dx = sin(rad) * step, dy = cos(rad) * step
        var out: [Double] = []
        out.reserveCapacity(n + 1)
        var base: Double?
        for i in 0...n {
            guard let e = elevation(x: start.x + dx * Double(i), y: start.y + dy * Double(i)) else { break }
            if base == nil { base = e }
            out.append(e - (base ?? 0))
        }
        return out
    }

    /// Elevation profile while walking a **path** whose per-bin compass `headings`
    /// drive each `step`-meter advance — so turns and curves are part of the
    /// fingerprint, not just a single straight bearing. Relative to the first
    /// sample; stops early if the path leaves the map.
    func pathProfile(from start: GeoPoint, headings: [Double], step: Double) -> [Double] {
        guard !headings.isEmpty else { return [] }
        var out: [Double] = []; out.reserveCapacity(headings.count)
        var cur = start
        var base: Double?
        for h in headings {
            guard let e = elevation(x: cur.x, y: cur.y) else { break }
            if base == nil { base = e }
            out.append(e - (base ?? 0))
            let rad = h * .pi / 180
            cur = GeoPoint(x: cur.x + sin(rad) * step, y: cur.y + cos(rad) * step)
        }
        return out
    }
}

/// A regular-grid DEM with bilinear interpolation. Row-major heights, `cellSize`
/// meters per cell, origin at grid index (0,0).
public final class GridDEM: DEMProvider {
    public let cols: Int
    public let rows: Int
    public let cellSize: Double
    public let originX: Double
    public let originY: Double
    private let h: [Double]

    public init(cols: Int, rows: Int, cellSize: Double,
                originX: Double = 0, originY: Double = 0, heights: [Double]) {
        precondition(heights.count == cols * rows, "heights must be cols*rows")
        self.cols = cols; self.rows = rows; self.cellSize = cellSize
        self.originX = originX; self.originY = originY; self.h = heights
    }

    public func elevation(x: Double, y: Double) -> Double? {
        let fx = (x - originX) / cellSize
        let fy = (y - originY) / cellSize
        if fx < 0 || fy < 0 || fx > Double(cols - 1) || fy > Double(rows - 1) { return nil }
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let x1 = min(x0 + 1, cols - 1), y1 = min(y0 + 1, rows - 1)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        let v00 = h[y0 * cols + x0], v10 = h[y0 * cols + x1]
        let v01 = h[y1 * cols + x0], v11 = h[y1 * cols + x1]
        let a = v00 + (v10 - v00) * tx
        let b = v01 + (v11 - v01) * tx
        return a + (b - a) * ty
    }
}
