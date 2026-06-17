import Foundation

/// Graph-constrained map matching — the "lost on a road" solver the rigid curve
/// matcher couldn't be. Instead of placing a free dead-reckoned curve (which
/// accumulates heading drift and wanders off real streets), we seed a hypothesis
/// at EVERY position on the road network (both directions) and, as the walk grows,
/// advance each one ALONG the roads — branching at intersections — scoring it by
/// how well the road it's travelling matches the walked heading AND how well the
/// DEM elevation along its route matches the barometer. Hypotheses that can't keep
/// matching die; the survivors collapse to where you actually are. Because the
/// roads carry the hypotheses, per-step heading noise can't build up drift.
///
/// Validated offline on a real field log + real OSM roads + DEM: 14,450 seeds
/// pruned to ~95, locking the true current position to ~28 m.
// @unchecked Sendable: the recovery view model hands a matcher to ONE background
// task at a time and never touches it from the main thread until that task hops
// back — so there is no concurrent access despite the mutable cloud.
public final class RouteMatcher: @unchecked Sendable {
    private let pts: [GeoPoint]      // node positions, local meters
    private let adj: [[Int]]         // adj[i] = neighbouring node indices
    private let dem: DEMProvider

    // Tunables (defaults match the validated prototype).
    public var headingSigmaDeg = 20.0   // how forgiving of heading-vs-road mismatch
                                        // 28° was too loose: parallel streets with 15° different
                                        // headings scored nearly as well as the true road.
    public var slopeSigma = 1.5         // metres PER STEP; tolerance on the climb/dip of each
                                        // bin. We match elevation SHAPE (per-step Δ), not the
                                        // absolute level — that cancels the DEM's constant
                                        // vertical bias (e.g. canopy bias under tree cover),
                                        // which otherwise drowned the contour signal entirely.
    public var branchGateDeg = 150.0    // allow even SHARP turns (loops) — a 90° gate pruned the true road at a turn
    public var beam = 18000             // keep more hypotheses alive so the truth survives a long walk
    public var mergeBucketM = 8.0       // collapse hypotheses landing on the same spot
    public var maxStepPenalty = 5.0     // cap one step's damage so a single bad/noisy bin can't delete the truth

    // `ePrev` = the DEM elevation this hypothesis was at on the PREVIOUS step, so we
    // can score the per-step climb (e − ePrev) against the per-step barometer climb.
    struct Walker { var a: Int; var b: Int; var s: Double; var logw: Double; var ePrev: Double }
    private var walkers: [Walker] = []
    private var prevObsCumElev = 0.0   // observed cumulative elevation at the last advance (for the per-step Δ)
    private var edgeSpeed: [Int64: Double] = [:]   // m/s per directed edge (driving mode)
    public var defaultSpeedMps = 13.0              // ~29 mph fallback when a road has no posted speed

    /// `edgeSpeedsMps`, if given, parallels `adjacency` (speed of edge a→adjacency[a][k]);
    /// only needed for driving mode.
    public init(nodes: [GeoPoint], adjacency: [[Int]], dem: DEMProvider, edgeSpeedsMps: [[Double]]? = nil) {
        pts = nodes; adj = adjacency; self.dem = dem
        if let sp = edgeSpeedsMps {
            for a in adjacency.indices { for (k, b) in adjacency[a].enumerated() where k < sp[a].count {
                edgeSpeed[skey(a, b)] = sp[a][k]
            }}
        }
    }
    private func skey(_ a: Int, _ b: Int) -> Int64 { Int64(a) &* 1_000_003 &+ Int64(b) }
    private func speedOf(_ a: Int, _ b: Int) -> Double { edgeSpeed[skey(a, b)] ?? defaultSpeedMps }

    private func len(_ a: Int, _ b: Int) -> Double { pts[a].distance(to: pts[b]) }
    private func bearing(_ a: Int, _ b: Int) -> Double {
        let d = atan2(pts[b].x - pts[a].x, pts[b].y - pts[a].y) * 180 / .pi
        return d < 0 ? d + 360 : d
    }
    private func posOf(_ w: Walker) -> GeoPoint {
        let L = len(w.a, w.b); let f = L > 0 ? w.s / L : 0
        return GeoPoint(x: pts[w.a].x + (pts[w.b].x - pts[w.a].x) * f,
                        y: pts[w.a].y + (pts[w.b].y - pts[w.a].y) * f)
    }
    private func angDiff(_ p: Double, _ q: Double) -> Double {
        abs((p - q + 540).truncatingRemainder(dividingBy: 360) - 180)   // 0…180
    }

    /// Drop a hypothesis every `spacingM` along every directed edge.
    public func seed(spacingM: Double) {
        walkers.removeAll()
        prevObsCumElev = 0.0
        for a in pts.indices {
            for b in adj[a] {
                let L = len(a, b); if L <= 0 { continue }
                var t = spacingM / 2
                while t < L {
                    let f = t / L
                    let p = GeoPoint(x: pts[a].x + (pts[b].x - pts[a].x) * f,
                                     y: pts[a].y + (pts[b].y - pts[a].y) * f)
                    if let e = dem.elevation(x: p.x, y: p.y) {
                        walkers.append(Walker(a: a, b: b, s: t, logw: 0, ePrev: e))
                    }
                    t += spacingM
                }
            }
        }
    }

    /// Advance the whole cloud along the roads (walking: same distance for every
    /// hypothesis). Scores against observed `headingDeg` + cumulative `cumElevM`.
    public func advance(distanceM step: Double, headingDeg h: Double, cumElevM oc: Double) {
        advanceCore({ _, _ in step }, headingDeg: h, cumElevM: oc)
    }

    /// Driving: each hypothesis advances by ITS road's speed limit × `speedScale` ×
    /// `seconds`. A hypothesis on a 25 mph street and one on a 55 mph highway cover
    /// very different ground in the same time — only the one whose speed-implied
    /// turns + elevation line up survives. `speedScale` (searched ~0.5–1.1) absorbs
    /// the gap between the posted limit and how fast you actually drive.
    public func advanceDriving(seconds dt: Double, headingDeg h: Double, cumElevM oc: Double, speedScale: Double) {
        advanceCore({ a, b in self.speedOf(a, b) * speedScale * dt }, headingDeg: h, cumElevM: oc)
    }

    private func advanceCore(_ distanceFor: (Int, Int) -> Double, headingDeg h: Double, cumElevM oc: Double) {
        guard !walkers.isEmpty else { return }
        var out: [Walker] = []; out.reserveCapacity(walkers.count * 2)
        for w in walkers {
            let step = distanceFor(w.a, w.b)
            var stack: [(a: Int, b: Int, s: Double, rem: Double)] = [(w.a, w.b, w.s, step)]
            var guardN = 0
            while let cur = stack.popLast() {
                guardN += 1; if guardN > 16 { break }
                let L = len(cur.a, cur.b)
                if cur.s + cur.rem <= L {
                    out.append(Walker(a: cur.a, b: cur.b, s: cur.s + cur.rem, logw: w.logw, ePrev: w.ePrev))
                } else {
                    let rem2 = cur.rem - (L - cur.s)
                    for c in adj[cur.b] where c != cur.a {
                        if angDiff(bearing(cur.b, c), h) <= branchGateDeg {
                            stack.append((cur.b, c, 0, rem2))
                        }
                    }
                }
            }
        }
        let sh2 = 2 * headingSigmaDeg * headingSigmaDeg, ss2 = 2 * slopeSigma * slopeSigma
        let dObs = oc - prevObsCumElev          // barometer climb over THIS step
        for i in out.indices {
            let dh = angDiff(bearing(out[i].a, out[i].b), h)
            var pen = dh * dh / sh2
            let p = posOf(out[i])
            if let e = dem.elevation(x: p.x, y: p.y) {
                // Match the SHAPE: this hypothesis's per-step climb vs the barometer's.
                // Differencing cancels any constant DEM-vs-baro offset (canopy bias),
                // which is exactly what made absolute-cumulative matching useless.
                let dDem = e - out[i].ePrev
                pen += (dDem - dObs) * (dDem - dObs) / ss2
                out[i].ePrev = e                // advance the reference for the next step
            }
            // Cap a single step's penalty: one glitchy bin (heading lag at a turn,
            // a momentary baro/DEM mismatch) must not annihilate an otherwise-good
            // hypothesis — that's what let the truth get pruned on long walks.
            out[i].logw -= min(pen, maxStepPenalty)
        }
        prevObsCumElev = oc
        // Merge hypotheses on the same spot (keep the best), then beam-prune.
        var best: [Int64: Int] = [:]
        for (idx, wk) in out.enumerated() {
            let k = (Int64(wk.a) &* 1_000_003 &+ Int64(wk.b)) &* 131 &+ Int64((wk.s / mergeBucketM).rounded())
            if let j = best[k] { if wk.logw > out[j].logw { best[k] = idx } } else { best[k] = idx }
        }
        var merged = best.values.map { out[$0] }
        if merged.count > beam { merged.sort { $0.logw > $1.logw }; merged.removeLast(merged.count - beam) }
        walkers = merged
    }

    /// Seed, then replay a whole walk given fixed-step heading + cumulative-elevation bins.
    public func matchWalk(stepM: Double, headings: [Double], cumElev: [Double], seedSpacingM: Double = 20) {
        seed(spacingM: seedSpacingM)
        for i in headings.indices {
            advance(distanceM: stepM, headingDeg: headings[i], cumElevM: i < cumElev.count ? cumElev[i] : 0)
        }
    }

    public var walkerCount: Int { walkers.count }
    public var livePositions: [GeoPoint] { walkers.map(posOf) }

    /// Where you most likely are NOW (heaviest hypothesis).
    public func estimate() -> GeoPoint? {
        guard let w = walkers.max(by: { $0.logw < $1.logw }) else { return nil }
        return posOf(w)
    }

    /// Probability mass within `radiusM` of the estimate — the lock metric.
    public func concentration(radiusM: Double) -> Double {
        guard let e = estimate(), let mx = walkers.map(\.logw).max() else { return 0 }
        var tot = 0.0, inside = 0.0
        for w in walkers {
            let wt = exp(w.logw - mx); tot += wt
            if posOf(w).distance(to: e) <= radiusM { inside += wt }
        }
        return tot > 0 ? inside / tot : 0
    }

    /// Seed so the whole network gets ≈`targetCount` hypotheses (picks spacing from
    /// total road length, so a big multi-area atlas doesn't explode the cloud).
    public func seed(targetCount: Int) {
        var total = 0.0
        for a in pts.indices { for b in adj[a] where b > a { total += len(a, b) } }
        seed(spacingM: Swift.max(12.0, total / Double(Swift.max(1, targetCount))))
    }

    /// A human answer / positive ID: keep only (or down-weight) hypotheses whose
    /// CURRENT position satisfies `keep`. `soft == 0` removes; otherwise multiplies.
    public func constrain(keep: (GeoPoint) -> Bool, soft: Double) {
        if soft <= 0 {
            walkers = walkers.filter { keep(posOf($0)) }
        } else {
            let ls = Foundation.log(soft)
            for i in walkers.indices where !keep(posOf(walkers[i])) { walkers[i].logw += ls }
        }
    }
    public func mask(_ impossible: (GeoPoint) -> Bool) { walkers.removeAll { impossible(posOf($0)) } }

    /// Weighted clusters of surviving hypotheses (heaviest first) — the candidate
    /// areas. Subsampled so clustering stays cheap on a big cloud.
    public func clusters(radiusM: Double, sample: Int = 1500) -> [(center: GeoPoint, weight: Double)] {
        guard let mx = walkers.map(\.logw).max() else { return [] }
        let stepN = Swift.max(1, walkers.count / sample)
        let ws = walkers.enumerated().filter { $0.offset % stepN == 0 }
            .map { (p: posOf($0.element), w: exp($0.element.logw - mx)) }
        let thr = (ws.map(\.w).max() ?? 0) * 0.05
        var used = [Bool](repeating: false, count: ws.count)
        var out: [(GeoPoint, Double)] = []
        for i in ws.indices where !used[i] && ws[i].w > thr {
            var sx = 0.0, sy = 0.0, sw = 0.0
            for k in ws.indices where !used[k] && ws[k].w > thr {
                if ws[i].p.distance(to: ws[k].p) <= radiusM {
                    used[k] = true; sx += ws[k].p.x * ws[k].w; sy += ws[k].p.y * ws[k].w; sw += ws[k].w
                }
            }
            if sw > 0 { out.append((GeoPoint(x: sx / sw, y: sy / sw), sw)) }
        }
        return out.sorted { $0.1 > $1.1 }
    }

    /// A weighted subsample of the surviving hypotheses (current position +
    /// normalized weight) — for scoring yes/no questions over the cloud.
    public func weightedSample(max n: Int) -> [(point: GeoPoint, weight: Double)] {
        guard let mx = walkers.map(\.logw).max() else { return [] }
        let stepN = Swift.max(1, walkers.count / n)
        return walkers.enumerated().filter { $0.offset % stepN == 0 }
            .map { (posOf($0.element), exp($0.element.logw - mx)) }
    }

    /// One-shot decision summary: best position, its share of the mass (lock
    /// metric), and how many distinct areas still survive.
    public func summary(radiusM: Double) -> (estimate: GeoPoint, concentration: Double, areas: Int)? {
        let cs = clusters(radiusM: radiusM)
        guard let top = cs.first else { return nil }
        let tot = cs.reduce(0) { $0 + $1.weight }
        return (top.center, tot > 0 ? top.weight / tot : 0, cs.count)
    }
}
