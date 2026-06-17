import Foundation

/// Dynamic Time Warping distance between two 1-D sequences.
///
/// Used to compare the walker's **time-sampled** barometric elevation profile
/// against a candidate's **distance-sampled** DEM profile: DTW stretches/squishes
/// the time axis so the match is independent of how fast the person walked. A
/// Sakoe-Chiba band keeps it O(N·band) instead of O(N·M) — vital with many
/// particles. Returns a length-normalized cost (0 = identical shape).
public enum DTW {
    public static func distance(_ a: [Double], _ b: [Double], bandFraction: Double = 0.2) -> Double {
        let n = a.count, m = b.count
        if n == 0 || m == 0 { return .greatestFiniteMagnitude }
        let band = max(abs(n - m) + 1, Int((Double(max(n, m)) * bandFraction).rounded(.up)))
        let inf = Double.greatestFiniteMagnitude
        var prev = [Double](repeating: inf, count: m + 1)
        prev[0] = 0
        for i in 1...n {
            var curr = [Double](repeating: inf, count: m + 1)
            let jLo = max(1, i - band), jHi = min(m, i + band)
            if jLo <= jHi {
                for j in jLo...jHi {
                    let cost = abs(a[i - 1] - b[j - 1])
                    let best = min(prev[j], min(curr[j - 1], prev[j - 1]))
                    if best < inf { curr[j] = cost + best }
                }
            }
            prev = curr
        }
        let raw = prev[m]
        return raw.isFinite ? raw / Double(n + m) : inf
    }

    /// Variance of a profile — the "flatland" detector. Near-zero ⇒ no terrain
    /// signature to match against (salt flats / uniform ground).
    public static func variance(_ p: [Double]) -> Double {
        guard p.count >= 2 else { return 0 }
        let mean = p.reduce(0, +) / Double(p.count)
        return p.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(p.count)
    }
}
