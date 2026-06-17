import Foundation

/// Deterministic, seedable RNG (SplitMix64) so the particle filter is testable
/// and reproducible. Conforms to `RandomNumberGenerator`, so the standard
/// `Double.random(in:using:)` etc. work with it.
public struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

public struct Particle: Equatable {
    public var x: Double
    public var y: Double
    public var weight: Double
    public init(x: Double, y: Double, weight: Double) { self.x = x; self.y = y; self.weight = weight }
    public var point: GeoPoint { GeoPoint(x: x, y: y) }
}

/// A particle cloud over possible locations, weighted by how well the DEM profile
/// along the walked heading matches the observed barometric profile (via DTW).
/// Solves the "kidnapped robot problem": scatter ghosts, walk + siphon, cull,
/// resample — repeat until the cloud collapses onto the true location.
public final class ParticleFilter {
    public private(set) var particles: [Particle]
    private let dem: DEMProvider

    public init(dem: DEMProvider, particles: [Particle] = []) {
        self.dem = dem; self.particles = particles
    }

    /// Uniformly scatter `count` ghosts in a disc of `radiusM` around `center`.
    /// `reject` (e.g. "is this point in a lake?") rejection-samples those out.
    public static func scatter<G: RandomNumberGenerator>(center: GeoPoint, radiusM: Double,
                                                         count: Int, using rng: inout G,
                                                         reject: (GeoPoint) -> Bool = { _ in false }) -> [Particle] {
        var ps: [Particle] = []; ps.reserveCapacity(count)
        let w = 1.0 / Double(max(count, 1))
        for _ in 0..<count {
            var p = GeoPoint(x: 0, y: 0)
            for _ in 0..<8 {                                  // a few tries to dodge rejected zones
                let r = radiusM * Double.random(in: 0...1, using: &rng).squareRoot()
                let a = Double.random(in: 0..<(2 * .pi), using: &rng)
                p = GeoPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
                if !reject(p) { break }
            }
            ps.append(Particle(x: p.x, y: p.y, weight: w))
        }
        return ps
    }

    public func seed<G: RandomNumberGenerator>(center: GeoPoint, radiusM: Double, count: Int,
                                               using rng: inout G, reject: (GeoPoint) -> Bool = { _ in false }) {
        particles = Self.scatter(center: center, radiusM: radiusM, count: count, using: &rng, reject: reject)
    }

    public func setParticles(_ ps: [Particle]) { particles = ps }

    /// Zero the weight of ghosts in an impossible zone (e.g. inside a lake) and
    /// renormalize. No-op if it would wipe the whole cloud.
    public func maskOut(_ impossible: (GeoPoint) -> Bool) {
        var masked = particles
        var total = 0.0
        for i in masked.indices where impossible(masked[i].point) { masked[i].weight = 0 }
        for p in masked { total += p.weight }
        guard total > 0 else { return }
        for i in masked.indices { masked[i].weight /= total }
        particles = masked
    }

    /// Re-weight every ghost by the likelihood that the DEM profile along
    /// `headingDeg` from its location matches `observed`. `sigma` is the match
    /// tolerance (smaller = stricter). This is *soft* — no ghost is deleted, only
    /// down-weighted — which is the asymmetric-trust principle in action.
    public func update(observed: [Double], headingDeg: Double, sigma: Double, profileStep: Double) {
        guard observed.count >= 2 else { return }
        let length = Double(observed.count - 1) * profileStep
        var total = 0.0
        for i in particles.indices {
            let prof = dem.profile(from: particles[i].point, headingDeg: headingDeg,
                                   length: length, step: profileStep)
            let w: Double
            if prof.count < 2 {
                w = 0                                   // ghost walked off the map
            } else {
                let d = DTW.distance(observed, prof)
                w = d.isFinite ? exp(-(d * d) / (2 * sigma * sigma)) : 0
            }
            particles[i].weight *= w
            total += particles[i].weight
        }
        if total > 0 { for i in particles.indices { particles[i].weight /= total } }
    }

    /// Re-weight ghosts by how well the DEM profile along the **walked path**
    /// (per-bin headings — turns and all) from each ghost matches `observed`.
    /// This fuses the whole trajectory into one fingerprint, which is far more
    /// discriminating than a single straight bearing.
    public func updatePath(observed: [Double], headings: [Double], step: Double, sigma: Double) {
        guard observed.count >= 2, headings.count == observed.count else { return }
        let minLen = max(2, observed.count / 2)
        var total = 0.0
        for i in particles.indices {
            let prof = dem.pathProfile(from: particles[i].point, headings: headings, step: step)
            var w = 0.0
            if prof.count >= minLen {
                let d = DTW.distance(observed, prof)
                w = d.isFinite ? exp(-(d * d) / (2 * sigma * sigma)) : 0
            }
            particles[i].weight *= w
            total += particles[i].weight
        }
        if total > 0 { for i in particles.indices { particles[i].weight /= total } }
    }

    /// Re-weight ghosts by how well the walked **road shape** replays onto roads
    /// from each one. `sharpness` exaggerates the contrast (pow on the on-road
    /// fraction) so a path that fits the roads dominates one that doesn't.
    public func weightByRoadPath(_ index: RoadIndex, headings: [Double], step: Double,
                                 tolerance: Double, sharpness: Double, rotationDeg: Double = 0) {
        guard !headings.isEmpty, !index.isEmpty else { return }
        var total = 0.0
        for i in particles.indices {
            let frac = index.pathAdherence(from: particles[i].point, headings: headings,
                                           step: step, tolerance: tolerance, rotationDeg: rotationDeg)
            particles[i].weight *= pow(frac, sharpness)
            total += particles[i].weight
        }
        if total > 0 { for i in particles.indices { particles[i].weight /= total } }
    }

    /// Systematic resampling with a small spatial jitter (avoids degeneracy /
    /// keeps the cloud able to refine). No-op if weights collapsed to zero.
    public func resample<G: RandomNumberGenerator>(jitterM: Double, using rng: inout G) {
        let n = particles.count
        guard n > 0 else { return }
        var cdf = [Double](); cdf.reserveCapacity(n)
        var acc = 0.0
        for p in particles { acc += p.weight; cdf.append(acc) }
        guard acc > 0 else { return }
        let step = acc / Double(n)
        let start = Double.random(in: 0..<step, using: &rng)
        var out: [Particle] = []; out.reserveCapacity(n)
        var j = 0
        for k in 0..<n {
            let u = start + Double(k) * step
            while j < n - 1 && cdf[j] < u { j += 1 }
            var np = particles[j]
            np.x += Double.random(in: -jitterM...jitterM, using: &rng)
            np.y += Double.random(in: -jitterM...jitterM, using: &rng)
            np.weight = 1.0 / Double(n)
            out.append(np)
        }
        particles = out
    }

    /// Weighted mean location of the cloud.
    public var estimate: GeoPoint {
        var sx = 0.0, sy = 0.0, sw = 0.0
        for p in particles { sx += p.x * p.weight; sy += p.y * p.weight; sw += p.weight }
        guard sw > 0 else { return GeoPoint(x: 0, y: 0) }
        return GeoPoint(x: sx / sw, y: sy / sw)
    }

    /// Weighted RMS spread of the cloud about its weighted mean (meters). Small
    /// ⇒ the probability mass has peaked on one place, even before resampling.
    public func weightedSpread() -> Double {
        let c = estimate
        var num = 0.0, sw = 0.0
        for p in particles { num += p.weight * p.point.distance(to: c) * p.point.distance(to: c); sw += p.weight }
        return sw > 0 ? (num / sw).squareRoot() : .greatestFiniteMagnitude
    }

    /// Fraction of probability mass within `radiusM` of `center` (default: the
    /// weighted estimate). Near 1 ⇒ the cloud has truly locked on one place —
    /// robust to a diffuse low-weight tail in a way RMS spread is not.
    public func weightConcentration(radiusM: Double, around center: GeoPoint? = nil) -> Double {
        let c = center ?? estimate
        var inside = 0.0, total = 0.0
        for p in particles { total += p.weight; if p.point.distance(to: c) <= radiusM { inside += p.weight } }
        return total > 0 ? inside / total : 0
    }

    /// Effective sample size — low ⇒ the cloud has concentrated on few hypotheses.
    public func effectiveSampleSize() -> Double {
        let s2 = particles.reduce(0) { $0 + $1.weight * $1.weight }
        return s2 > 0 ? 1.0 / s2 : 0
    }

    /// Greedily group ghosts into spatial clusters (centroids), largest first —
    /// used to detect "down to 2-3 candidate locations" for the tie-breaker.
    public func clusters(radiusM: Double) -> [(center: GeoPoint, count: Int, weight: Double)] {
        var assigned = [Bool](repeating: false, count: particles.count)
        var out: [(GeoPoint, Int, Double)] = []
        for i in particles.indices where !assigned[i] {
            var sx = 0.0, sy = 0.0, sw = 0.0, cnt = 0
            for k in particles.indices where !assigned[k] {
                if particles[i].point.distance(to: particles[k].point) <= radiusM {
                    assigned[k] = true
                    sx += particles[k].x; sy += particles[k].y; sw += particles[k].weight; cnt += 1
                }
            }
            if cnt > 0 { out.append((GeoPoint(x: sx / Double(cnt), y: sy / Double(cnt)), cnt, sw)) }
        }
        return out.sorted { $0.2 > $1.2 }   // heaviest cluster first
    }

    /// How many distinct candidate areas really remain — the number of clusters
    /// (heaviest first) needed to cover `coverage` of the probability mass. Ignores
    /// the low-weight tail, so it reflects "how many places could I be," which gates
    /// when it's worth switching from walking to yes/no questions.
    public func candidateCount(radiusM: Double, coverage: Double = 0.85) -> Int {
        let cs = clusters(radiusM: radiusM)
        let total = cs.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return cs.count }
        var acc = 0.0, n = 0
        for c in cs { acc += c.weight; n += 1; if acc >= coverage * total { break } }
        return n
    }
}
