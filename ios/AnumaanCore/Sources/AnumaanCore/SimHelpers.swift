import Foundation

/// Reproducible pseudo-random source for synthetic sensor noise.
public struct LCG {
    public var s: UInt64
    public init(seed: UInt64) { s = seed | 1 }
    public mutating func unit() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53)
    }
    public mutating func gauss(_ sigma: Double) -> Double {
        let u1 = Swift.max(1e-12, unit()), u2 = unit()
        return sigma * (-2 * Foundation.log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// Compass bearing a -> b (0 = north/+y, 90 = east/+x).
public func compassBearing(_ a: GeoPoint, _ b: GeoPoint) -> Double {
    let d = atan2(b.x - a.x, b.y - a.y) * 180 / .pi
    return d < 0 ? d + 360 : d
}

public func polylineLength(_ poly: [GeoPoint]) -> Double {
    zip(poly, poly.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
}

/// Position + heading at arc-length `dist` along a polyline.
public func sampleAlong(_ poly: [GeoPoint], at dist: Double) -> (pos: GeoPoint, heading: Double) {
    var d = dist
    for i in 0..<(poly.count - 1) {
        let a = poly[i], b = poly[i + 1], L = a.distance(to: b)
        if d <= L || i == poly.count - 2 {
            let f = L > 0 ? Swift.max(0, Swift.min(1, d / L)) : 0
            return (GeoPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), compassBearing(a, b))
        }
        d -= L
    }
    return (poly.last ?? GeoPoint(x: 0, y: 0), 0)
}

/// Turn a true polyline into a noisy walk the matcher replays: per-`stepM` compass
/// heading + cumulative (relative) barometric elevation, with Gaussian sensor noise.
public func synthesizeWalk(poly: [GeoPoint], stepM: Double,
                           headingNoiseDeg: Double, baroNoiseM: Double,
                           elevation: (GeoPoint) -> Double,
                           rng: inout LCG) -> (headings: [Double], cumElev: [Double]) {
    let total = polylineLength(poly)
    let bins = Swift.max(0, Int(total / stepM))
    guard bins > 0 else { return ([], []) }
    let base = elevation(poly.first ?? GeoPoint(x: 0, y: 0))
    var headings: [Double] = [], cumElev: [Double] = []
    for k in 1...bins {
        let s = sampleAlong(poly, at: Double(k) * stepM)
        headings.append(s.heading + rng.gauss(headingNoiseDeg))
        cumElev.append(elevation(s.pos) - base + rng.gauss(baroNoiseM))
    }
    return (headings, cumElev)
}

/// Seed and advance the route matcher over a synthesized walk.
public func runMatcher(nodes: [GeoPoint], adjacency: [[Int]], dem: DEMProvider,
                       headings: [Double], cumElev: [Double],
                       stepM: Double, seeds: Int) -> RouteMatcher {
    let m = RouteMatcher(nodes: nodes, adjacency: adjacency, dem: dem)
    m.seed(targetCount: seeds)
    for k in headings.indices { m.advance(distanceM: stepM, headingDeg: headings[k], cumElevM: cumElev[k]) }
    return m
}
