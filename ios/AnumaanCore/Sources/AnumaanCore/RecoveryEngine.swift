import Foundation

/// Outcome of one walk-and-cull cycle of the "I'm Lost" protocol.
public enum RecoveryStatus: Equatable {
    case scattered(Int)                 // ghosts dropped, awaiting first walk
    case searching(clusters: Int, ess: Double)   // still ambiguous, keep walking
    case flatline                       // no terrain signature — change tactics
    case ambiguous([GeoPoint])          // 2-3 candidate clusters — ask a tie-breaker
    case located(GeoPoint)              // location lock
}

/// Drives the probabilistic rescue: scatter → walk/siphon → cull → resample,
/// with the spec's edge-case mitigations (flatline detection; lock vs ambiguous).
/// The barometer/compass wiring and the human "look west" interrogations live in
/// the iOS layer; this is the pure, testable decision core.
public final class RecoveryEngine {
    public struct Config {
        public var profileStep: Double = 30      // m between DEM samples (DEM resolution)
        public var matchSigma: Double = 6         // DTW match tolerance (m of shape error)
        public var jitterM: Double = 15           // resample spread
        public var clusterRadiusM: Double = 120   // how close ghosts must be to be "one place"
        public var lockRadiusM: Double = 120      // mass within this of the estimate ⇒ a lock
        public var lockMassFraction: Double = 0.6 // …if at least this much weight is inside it
        public var flatlineVariance: Double = 1.0 // m² — below this the walk was flat
        public var maxClustersForTiebreak = 3
        public init() {}
    }

    private let dem: DEMProvider
    public let pf: ParticleFilter
    private var rng: SeededRNG
    public var config: Config
    /// Optional map features — lets us keep ghosts out of water and ask feature
    /// questions ("stream on your right?").
    public var featureField: FeatureField?

    public init(dem: DEMProvider, seed: UInt64 = 0x5EED, config: Config = Config(),
                featureField: FeatureField? = nil) {
        self.dem = dem
        self.pf = ParticleFilter(dem: dem)
        self.rng = SeededRNG(seed: seed)
        self.config = config
        self.featureField = featureField
    }

    /// The Ghost Drop: scatter `count` candidate locations across the radius —
    /// skipping water (a person can't be standing in a lake).
    @discardableResult
    public func begin(center: GeoPoint, radiusM: Double, count: Int) -> RecoveryStatus {
        let ff = featureField
        pf.seed(center: center, radiusM: radiusM, count: count, using: &rng,
                reject: { ff?.containing([.water], point: $0) != nil })
        maskWater()
        return .scattered(count)
    }

    /// The Ghost Drop constrained to ROADS — when the user says they started on a
    /// paved road, every hypothesis starts on a road (a far stronger prior than a
    /// uniform disc, most of which is off-road).
    @discardableResult
    public func beginOnRoads(_ index: RoadIndex, count: Int) -> RecoveryStatus {
        let pts = index.sampleOnRoad(count: count, jitterM: 8, using: &rng)
        guard !pts.isEmpty else { return .scattered(0) }
        let w = 1.0 / Double(pts.count)
        pf.setParticles(pts.map { Particle(x: $0.x, y: $0.y, weight: w) })
        maskWater()
        return .scattered(pts.count)
    }

    /// Zero out any ghost that drifted into water (call after each resample).
    private func maskWater() {
        guard let ff = featureField else { return }
        pf.maskOut { ff.containing([.water], point: $0) != nil }
    }

    /// One Sensor-Siphon cycle: feed the just-walked relative barometric profile
    /// and the locked compass heading; cull, and resample only once the cloud has
    /// genuinely concentrated (adaptive resampling — resampling every step just
    /// diffuses the cloud and destroys the accumulated evidence).
    public func step(barometricProfile observed: [Double], headingDeg: Double) -> RecoveryStatus {
        // Flatland trap: a flat walk carries no information — don't cull on noise.
        if DTW.variance(observed) < config.flatlineVariance { return .flatline }

        pf.update(observed: observed, headingDeg: headingDeg,
                  sigma: config.matchSigma, profileStep: config.profileStep)
        let n = pf.particles.count
        if pf.effectiveSampleSize() < Double(n) * 0.5 {
            pf.resample(jitterM: config.jitterM, using: &rng)
            maskWater()
        }
        return assess()
    }

    /// Like `step`, but matches the whole walked **path** (per-bin headings, so
    /// turns/curves are part of the signature) — fuses multiple walks into one cull.
    public func stepPath(observedProfile observed: [Double], headings: [Double]) -> RecoveryStatus {
        if DTW.variance(observed) < config.flatlineVariance { return .flatline }
        pf.updatePath(observed: observed, headings: headings,
                      step: config.profileStep, sigma: config.matchSigma)
        let n = pf.particles.count
        if pf.effectiveSampleSize() < Double(n) * 0.5 {
            pf.resample(jitterM: config.jitterM, using: &rng)
            maskWater()
        }
        return assess()
    }

    /// Cull by the walked path's ROAD SHAPE — the strongest constraint when the
    /// person walked on roads. A distinctive curve fits very few road locations.
    public func cullByRoadPath(_ index: RoadIndex, headings: [Double],
                               tolerance: Double = 25, sharpness: Double = 6) -> RecoveryStatus {
        pf.weightByRoadPath(index, headings: headings, step: config.profileStep,
                            tolerance: tolerance, sharpness: sharpness)
        let n = pf.particles.count
        if pf.effectiveSampleSize() < Double(n) * 0.5 {
            pf.resample(jitterM: config.jitterM, using: &rng)
            maskWater()
        }
        return assess()
    }

    /// Classify the current cloud (lock / ambiguous / searching) without ingesting
    /// a new walk — used after a tie-breaker interrogation prunes the ghosts.
    public func assess() -> RecoveryStatus {
        if pf.weightConcentration(radiusM: config.lockRadiusM) >= config.lockMassFraction {
            return .located(pf.estimate)
        }
        let clusters = pf.clusters(radiusM: config.clusterRadiusM)
        if clusters.count >= 2 && clusters.count <= config.maxClustersForTiebreak,
           clusters.prefix(config.maxClustersForTiebreak).reduce(0, { $0 + $1.weight }) > 0.6 {
            return .ambiguous(clusters.map(\.center))
        }
        return .searching(clusters: clusters.count, ess: pf.effectiveSampleSize())
    }

    /// Tie-breaker / asymmetric-trust pruning applied after a human answer:
    /// down-weight ghosts that disagree (soft) or, for an undeniable negative,
    /// hard-prune them. `keep` returns true for a ghost consistent with the answer.
    /// `hard` = true only for massive, undeniable negative constraints.
    public func applyInterrogation(hard: Bool, keep: (GeoPoint) -> Bool) {
        var ps = pf.particles
        for i in ps.indices {
            if keep(ps[i].point) { continue }
            ps[i].weight *= hard ? 0.0 : 0.25   // hard delete vs soft down-weight
        }
        let total = ps.reduce(0) { $0 + $1.weight }
        if total > 0 { for i in ps.indices { ps[i].weight /= total } }
        pf.setParticles(ps)
        pf.resample(jitterM: config.jitterM, using: &rng)
    }
}
