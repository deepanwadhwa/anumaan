import Foundation

/// A spatially-indexed set of road segments (local meters) with a fast
/// nearest-road query and — the key tool for recovery — a *path adherence* score:
/// replay the walked heading-shape from a candidate start and measure how much of
/// it stays on roads. The true start replays along the actual roads (adherence
/// ≈ 1); a wrong start sends the same distinctive shape across open terrain
/// (adherence low). On a road network, a curvy walked path fits very few places —
/// exactly the constraint a lost person on a paved road gives us.
public final class RoadIndex {
    private let cell: Double
    private let segs: [(a: GeoPoint, b: GeoPoint)]
    private var grid: [Int64: [Int]] = [:]

    public init(segments: [(GeoPoint, GeoPoint)], cell: Double = 60) {
        self.cell = cell
        self.segs = segments.map { (a: $0.0, b: $0.1) }
        for (i, s) in segs.enumerated() {
            let minCx = Int((min(s.a.x, s.b.x) / cell).rounded(.down))
            let maxCx = Int((max(s.a.x, s.b.x) / cell).rounded(.down))
            let minCy = Int((min(s.a.y, s.b.y) / cell).rounded(.down))
            let maxCy = Int((max(s.a.y, s.b.y) / cell).rounded(.down))
            for cx in minCx...maxCx { for cy in minCy...maxCy { grid[key(cx, cy), default: []].append(i) } }
        }
    }

    public var isEmpty: Bool { segs.isEmpty }

    /// Sample `count` points spread along the road network (length-weighted, with a
    /// little perpendicular jitter) — the ghost cloud when the user says they're on
    /// a paved road, so every hypothesis already starts on a road.
    public func sampleOnRoad<G: RandomNumberGenerator>(count: Int, jitterM: Double,
                                                       using rng: inout G) -> [GeoPoint] {
        guard !segs.isEmpty else { return [] }
        var cum = [Double](); cum.reserveCapacity(segs.count)
        var total = 0.0
        for s in segs { total += s.a.distance(to: s.b); cum.append(total) }
        guard total > 0 else { return [] }
        var out: [GeoPoint] = []; out.reserveCapacity(count)
        for _ in 0..<count {
            let u = Double.random(in: 0..<total, using: &rng)
            var lo = 0, hi = cum.count - 1
            while lo < hi { let mid = (lo + hi) / 2; if cum[mid] < u { lo = mid + 1 } else { hi = mid } }
            let s = segs[lo]
            let t = Double.random(in: 0...1, using: &rng)
            out.append(GeoPoint(x: s.a.x + (s.b.x - s.a.x) * t + Double.random(in: -jitterM...jitterM, using: &rng),
                                y: s.a.y + (s.b.y - s.a.y) * t + Double.random(in: -jitterM...jitterM, using: &rng)))
        }
        return out
    }

    private func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) &* 1_000_003 &+ Int64(y) }

    public func nearestDistance(to p: GeoPoint) -> Double {
        nearestRoad(to: p)?.dist ?? .greatestFiniteMagnitude
    }

    /// The closest point ON the network to `p`, and how far it is — for "which way
    /// is the nearest road/trail" egress guidance when you're lost in the woods.
    /// Brute force over all segments (the network may be far, beyond the local grid).
    public func nearest(to p: GeoPoint) -> (point: GeoPoint, dist: Double)? {
        guard !segs.isEmpty else { return nil }
        var best = Double.greatestFiniteMagnitude, bp = segs[0].a
        for s in segs {
            let ax = s.a.x, ay = s.a.y, dx = s.b.x - ax, dy = s.b.y - ay
            let L = dx * dx + dy * dy
            let t = L == 0 ? 0 : max(0, min(1, ((p.x - ax) * dx + (p.y - ay) * dy) / L))
            let cx = ax + t * dx, cy = ay + t * dy
            let d = ((p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy)).squareRoot()
            if d < best { best = d; bp = GeoPoint(x: cx, y: cy) }
        }
        return (bp, best)
    }

    /// Nearest road segment to `p`: its perpendicular distance AND its compass
    /// bearing (0 = N, 90 = E) — so callers can require the walk to run ALONG the
    /// road, not merely pass near it.
    public func nearestRoad(to p: GeoPoint) -> (dist: Double, bearingDeg: Double)? {
        let cx = Int((p.x / cell).rounded(.down)), cy = Int((p.y / cell).rounded(.down))
        var best = Double.greatestFiniteMagnitude, bi = -1
        for dx in -1...1 { for dy in -1...1 {
            for i in grid[key(cx + dx, cy + dy)] ?? [] {
                let d = Geo.pointToSegment(p, segs[i].a, segs[i].b).0
                if d < best { best = d; bi = i }
            }
        }}
        guard bi >= 0 else { return nil }
        let s = segs[bi]
        let br = atan2(s.b.x - s.a.x, s.b.y - s.a.y) * 180 / .pi
        return (best, (br + 360).truncatingRemainder(dividingBy: 360))
    }

    /// How well the replayed walk FOLLOWS roads (0…1) — not just "near a road".
    /// Each step scores high only when it is both close to a road AND travelling
    /// along that road's direction; a path that cuts across a street grid (heading
    /// perpendicular to the roads it passes) scores ~0 even though it is constantly
    /// near roads. THIS is what makes a curvy walk fit very few places in a town.
    /// `rotationDeg` rotates the whole shape (unknown phone orientation in a pocket).
    public func pathAdherence(from start: GeoPoint, headings: [Double], step: Double,
                              tolerance: Double, rotationDeg: Double = 0,
                              headingToleranceDeg: Double = 40) -> Double {
        guard !headings.isEmpty else { return 0 }
        var cur = start, score = 0.0
        for h in headings {
            if let nr = nearestRoad(to: cur), nr.dist <= tolerance {
                // Angle between travel and road, folded to 0…90° (roads are two-way).
                var dh = abs(((h + rotationDeg - nr.bearingDeg) + 540).truncatingRemainder(dividingBy: 360) - 180)
                if dh > 90 { dh = 180 - dh }
                if dh <= headingToleranceDeg {
                    let dirW = 1 - dh / headingToleranceDeg       // 1 along road → 0 across it
                    let distW = 1 - nr.dist / tolerance           // 1 on road → 0 at tolerance edge
                    score += dirW * distW
                }
            }
            let r = (h + rotationDeg) * .pi / 180
            cur = GeoPoint(x: cur.x + sin(r) * step, y: cur.y + cos(r) * step)
        }
        return score / Double(headings.count)
    }

    /// The phone may be rotated by a constant unknown angle in a pocket. Since the
    /// *shape* survives, recover that angle: the rotation at which the walked path
    /// best snaps onto the roads at SOME candidate start. Returns (rotation°, peak
    /// adherence).
    /// `maxDeg` bounds the search to ±maxDeg around 0. The declination-corrected
    /// compass is reliable (≈7° off travel direction in field tests), so a *narrow*
    /// window corrects a tilted phone WITHOUT the spurious far-rotation fits that a
    /// full 360° search produces in a dense road network. Ties prefer smaller |rot|.
    public func estimateRotation(candidates: [GeoPoint], headings: [Double], step: Double,
                                 tolerance: Double, rotationStepDeg: Double = 5,
                                 maxDeg: Double = 45) -> (rotation: Double, peak: Double) {
        guard !candidates.isEmpty, !headings.isEmpty else { return (0, 0) }
        var best = (rotation: 0.0, peak: -1.0)
        var rot = -maxDeg
        while rot <= maxDeg {
            var peak = 0.0
            for c in candidates {
                let a = pathAdherence(from: c, headings: headings, step: step,
                                      tolerance: tolerance, rotationDeg: rot)
                if a > peak { peak = a; if peak >= 0.999 { break } }
            }
            if peak > best.peak + 0.001 || (abs(peak - best.peak) <= 0.001 && abs(rot) < abs(best.rotation)) {
                best = (rot, peak)
            }
            rot += rotationStepDeg
        }
        return best
    }
}
