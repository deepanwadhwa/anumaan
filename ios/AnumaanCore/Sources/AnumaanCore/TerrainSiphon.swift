import Foundation

/// Turns the walk's **time-sampled** barometer stream into the **distance-sampled**
/// relative elevation profile the recovery engine matches against the DEM.
///
/// The barometer gives altitude over *time*; the DEM profile is over *distance*.
/// With no GPS, distance comes from step-count odometry (steps × stride). We bin
/// altitude into `step`-meter distance bins so the observed profile is directly
/// comparable to `DEMProvider.profile(...)`. (DTW then absorbs the residual
/// stride/speed error — this just gets the length scale right.)
public enum TerrainSiphon {
    /// `altitudes[i]` paired with monotonic `distances[i]` (meters). Returns a
    /// relative profile sampled every `step` meters, or [] if the walk was too
    /// short to fill one bin.
    public static func distanceProfile(altitudes: [Double], distances: [Double], step: Double) -> [Double] {
        guard altitudes.count == distances.count, altitudes.count >= 2, step > 0,
              let d0 = distances.first, let dN = distances.last, dN - d0 >= step else { return [] }
        let bins = Int((dN - d0) / step)
        var out: [Double] = []; out.reserveCapacity(bins + 1)
        var j = 0
        for i in 0...bins {
            let target = d0 + Double(i) * step
            while j < distances.count - 2 && distances[j + 1] < target { j += 1 }
            let da = distances[j], db = distances[j + 1]
            let t = db > da ? min(max((target - da) / (db - da), 0), 1) : 0
            out.append(altitudes[j] + (altitudes[j + 1] - altitudes[j]) * t)
        }
        let base = out.first ?? 0
        return out.map { $0 - base }
    }
}

/// Bins a walked track — synchronized (distance, altitude, heading) samples — into
/// a per-`step` relative elevation profile AND the heading at each bin, so the
/// whole path shape (straights, curves, the turn) can be matched against the DEM.
public enum PathSiphon {
    public static func build(distances: [Double], altitudes: [Double], headings: [Double],
                             step: Double) -> (profile: [Double], headings: [Double]) {
        guard distances.count == altitudes.count, distances.count == headings.count,
              distances.count >= 2, step > 0,
              let d0 = distances.first, let dN = distances.last, dN - d0 >= step else { return ([], []) }
        let bins = Int((dN - d0) / step)
        var prof: [Double] = []; var hdg: [Double] = []
        var j = 0
        for i in 0...bins {
            let target = d0 + Double(i) * step
            while j < distances.count - 2 && distances[j + 1] < target { j += 1 }
            let da = distances[j], db = distances[j + 1]
            let t = db > da ? min(max((target - da) / (db - da), 0), 1) : 0
            prof.append(altitudes[j] + (altitudes[j + 1] - altitudes[j]) * t)
            hdg.append(t < 0.5 ? headings[j] : headings[j + 1])
        }
        let base = prof.first ?? 0
        return (prof.map { $0 - base }, hdg)
    }
}
