import Foundation

/// Finds the curve you walked on the map. No particles, no resampling, no
/// wandering: a FIXED set of candidate start positions is scored by how well the
/// walked curve — its road shape AND its elevation profile, at its true
/// compass orientation — fits the map when placed there. We keep the whole score
/// surface and take the best, so a good candidate is never deleted. Yes/no
/// answers and a named street just multiply constraints onto the same surface.
public final class CurveMatcher {
    private let dem: DEMProvider
    private let roads: RoadIndex?
    public let candidates: [GeoPoint]
    private var pathScore: [Double]      // fit of the walked curve (road + elevation)
    private var constraint: [Double]     // accumulated yes/no + named answers
    public private(set) var weight: [Double]

    // Deliberately fuzzy: a wide road tolerance + gentle sharpness so accumulated
    // dead-reckoning drift over a long walk degrades the fit gracefully instead of
    // killing it; DTW already makes the elevation match shape-based, not pointwise.
    public var profileStep = 30.0
    public var roadTolerance = 30.0
    public var roadSharpness = 4.0
    public var elevSigma = 5.0

    public init(dem: DEMProvider, roads: RoadIndex?, candidates: [GeoPoint]) {
        self.dem = dem; self.roads = roads; self.candidates = candidates
        let n = candidates.count
        pathScore = Array(repeating: 1, count: n)
        constraint = Array(repeating: 1, count: n)
        weight = Array(repeating: 1.0 / Double(max(n, 1)), count: n)
    }

    /// Re-score every candidate against the WHOLE walked curve so far.
    public func scorePath(headings: [Double], profile: [Double]) {
        guard !headings.isEmpty else { return }
        let minLen = max(2, profile.count / 2)
        for i in candidates.indices {
            var s = 1.0
            if let roads, !roads.isEmpty {
                let frac = roads.pathAdherence(from: candidates[i], headings: headings,
                                               step: profileStep, tolerance: roadTolerance)
                s *= pow(frac, roadSharpness)
            }
            if s > 0, profile.count >= 3 {
                let prof = dem.pathProfile(from: candidates[i], headings: headings, step: profileStep)
                if prof.count >= minLen {
                    let d = DTW.distance(profile, prof)
                    s *= d.isFinite ? exp(-(d * d) / (2 * elevSigma * elevSigma)) : 0
                } else { s = 0 }   // curve ran off the map here
            }
            pathScore[i] = s
        }
        normalize()
    }

    /// A yes/no answer evaluated at the curve's CURRENT end (candidate + endOffset).
    public func constrain(endOffset: GeoPoint, hard: Bool, keep: (GeoPoint) -> Bool) {
        let f = hard ? 0.0 : 0.25
        for i in candidates.indices {
            let here = GeoPoint(x: candidates[i].x + endOffset.x, y: candidates[i].y + endOffset.y)
            if !keep(here) { constraint[i] *= f }
        }
        normalize()
    }

    public func maskOut(_ impossible: (GeoPoint) -> Bool) {
        for i in candidates.indices where impossible(candidates[i]) { constraint[i] = 0 }
        normalize()
    }

    private func normalize() {
        var tot = 0.0
        for i in candidates.indices { weight[i] = pathScore[i] * constraint[i]; tot += weight[i] }
        if tot > 0 { for i in candidates.indices { weight[i] /= tot } }
    }

    // MARK: estimates

    /// Weighted clusters (heaviest first) — the real candidate areas.
    public func clusters(radiusM: Double) -> [(center: GeoPoint, weight: Double)] {
        let thr = (weight.max() ?? 0) * 0.02
        var assigned = [Bool](repeating: false, count: candidates.count)
        var out: [(GeoPoint, Double)] = []
        for i in candidates.indices where !assigned[i] && weight[i] > thr {
            var sx = 0.0, sy = 0.0, sw = 0.0
            for k in candidates.indices where !assigned[k] && weight[k] > thr {
                if candidates[i].distance(to: candidates[k]) <= radiusM {
                    assigned[k] = true
                    sx += candidates[k].x * weight[k]; sy += candidates[k].y * weight[k]; sw += weight[k]
                }
            }
            if sw > 0 { out.append((GeoPoint(x: sx / sw, y: sy / sw), sw)) }
        }
        return out.sorted { $0.1 > $1.1 }
    }

    /// The leading hypothesis (heaviest cluster centroid) — stable, NOT a wandering mean.
    public var lead: GeoPoint { clusters(radiusM: 120).first?.center ?? estimate }

    public var estimate: GeoPoint {
        var sx = 0.0, sy = 0.0, sw = 0.0
        for i in candidates.indices { sx += candidates[i].x * weight[i]; sy += candidates[i].y * weight[i]; sw += weight[i] }
        return sw > 0 ? GeoPoint(x: sx / sw, y: sy / sw) : (candidates.first ?? GeoPoint(x: 0, y: 0))
    }

    public func candidateCount(radiusM: Double, coverage: Double = 0.85) -> Int {
        let cs = clusters(radiusM: radiusM); let tot = cs.reduce(0) { $0 + $1.weight }
        guard tot > 0 else { return cs.count }
        var acc = 0.0, n = 0
        for c in cs { acc += c.weight; n += 1; if acc >= coverage * tot { break } }
        return n
    }

    /// Mass within `radiusM` of the leading cluster — high ⇒ locked.
    public func leadConcentration(radiusM: Double) -> Double {
        let c = lead; var inside = 0.0, tot = 0.0
        for i in candidates.indices { tot += weight[i]; if candidates[i].distance(to: c) <= radiusM { inside += weight[i] } }
        return tot > 0 ? inside / tot : 0
    }

    /// Candidates still in contention (for the map overlay).
    public func live() -> [GeoPoint] {
        let thr = (weight.max() ?? 0) * 0.05
        return candidates.indices.filter { weight[$0] > thr }.map { candidates[$0] }
    }
}
