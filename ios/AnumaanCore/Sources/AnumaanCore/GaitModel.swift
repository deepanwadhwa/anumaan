import Foundation

/// Learns the relationship between step **cadence** (steps/sec, from the phone's
/// accelerometer) and ground **speed** (m/s, known whenever a milestone is
/// confirmed: leg distance ÷ leg time). Once trained it predicts live speed from
/// live cadence, so the dot keeps pace with how fast you're actually walking —
/// not a fixed guess between milestones.
///
/// - 1 sample  → proportional (stride length = speed/cadence, line through origin)
/// - ≥2 samples → least-squares line speed = slope·cadence + intercept
///
/// Falls back to "untrained" (returns nil) when no walking cadence has been seen
/// — e.g. in a car — so the caller can keep dead-reckoning at a constant pace.
public final class GaitModel {
    public struct Sample: Equatable { public let cadence: Double; public let speed: Double }
    public private(set) var samples: [Sample] = []
    private let maxSamples = 8
    // Plausible human range, so a bad observation can't poison the model.
    private let minCadence = 0.5    // steps/sec
    private let maxSpeed = 8.0      // m/s (fast run)

    public init() {}
    public func reset() { samples = [] }

    public var trained: Bool { !samples.isEmpty }

    /// Record a (cadence, speed) observation from a completed, confirmed leg.
    public func observe(cadence: Double, speed: Double) {
        guard cadence >= minCadence, speed > 0, speed <= maxSpeed else { return }
        samples.append(Sample(cadence: cadence, speed: speed))
        if samples.count > maxSamples { samples.removeFirst() }
    }

    /// Learned stride length (m/step) — only meaningful with ≥1 sample.
    public var strideLength: Double {
        guard let s = samples.last, s.cadence > 0 else { return 0 }
        return s.speed / s.cadence
    }

    /// Predict speed (m/s) for a live cadence, or nil if not yet trained.
    public func predict(cadence: Double) -> Double? {
        guard trained else { return nil }
        if cadence <= 0.05 { return 0 }                    // standing still
        if samples.count == 1 {
            let s = samples[0]
            return max(0, s.speed / s.cadence * cadence)   // through-origin stride model
        }
        // least squares: speed = a·cadence + b
        let n = Double(samples.count)
        let sx = samples.reduce(0) { $0 + $1.cadence }
        let sy = samples.reduce(0) { $0 + $1.speed }
        let sxx = samples.reduce(0) { $0 + $1.cadence * $1.cadence }
        let sxy = samples.reduce(0) { $0 + $1.cadence * $1.speed }
        let denom = n * sxx - sx * sx
        guard abs(denom) > 1e-9 else { return max(0, sy / n) }
        let a = (n * sxy - sx * sy) / denom
        let b = (sy - a * sx) / n
        return max(0, a * cadence + b)
    }
}
