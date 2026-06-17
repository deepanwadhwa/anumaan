import Foundation

/// Geometry helpers for turns and bearings (port of `anumaan/turn.py`).
public enum Turn {
    public static let significantDeg = 30.0   // smaller ⇒ "continue straight"

    /// Wrap an angle into [0, 360).
    public static func wrap360(_ a: Double) -> Double {
        let r = a.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Signed shortest difference a-b in (-180, 180].
    public static func angleDiff(_ a: Double, _ b: Double) -> Double {
        ((a - b + 180).truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) - 180
    }

    /// Initial compass bearing (deg, 0=N, clockwise) from point a to b.
    public static func bearing(_ a: (lat: Double, lon: Double),
                               _ b: (lat: Double, lon: Double)) -> Double {
        let lat1 = a.lat * .pi / 180, lat2 = b.lat * .pi / 180
        let dlon = (b.lon - a.lon) * .pi / 180
        let y = sin(dlon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dlon)
        return wrap360(atan2(y, x) * 180 / .pi)
    }

    /// Signed turn at `node` in degrees, (-180, 180]. Positive = right (CW).
    public static func turnAngle(prev: (lat: Double, lon: Double),
                                 node: (lat: Double, lon: Double),
                                 next: (lat: Double, lon: Double)) -> Double {
        var delta = bearing(node, next) - bearing(prev, node)
        delta = (delta + 180).truncatingRemainder(dividingBy: 360)
        if delta < 0 { delta += 360 }
        return delta - 180
    }

    /// Human label for a signed turn angle.
    public static func classify(_ angle: Double) -> String {
        let a = abs(angle)
        if a < significantDeg { return "straight" }
        let side = angle > 0 ? "right" : "left"
        if a >= 150 { return "sharp \(side) (U-turn)" }
        if a >= 100 { return "sharp \(side)" }
        if a >= 55 { return side }
        return "slight \(side)"
    }

    /// Great-circle distance in meters.
    public static func haversine(_ a: (lat: Double, lon: Double),
                                 _ b: (lat: Double, lon: Double)) -> Double {
        let r = 6_371_000.0
        let p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180
        let dLat = (b.lat - a.lat) * .pi / 180, dLon = (b.lon - a.lon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(p1) * cos(p2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
