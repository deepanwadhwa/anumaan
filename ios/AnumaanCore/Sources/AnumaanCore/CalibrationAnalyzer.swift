import Foundation

/// The first-leg learning step the user described:
///
///  1. Ground truth = leg distance ÷ leg time (an *accurate* speed, because both
///     ends are known landmarks).
///  2. While walking that leg we record the sensor stream (cumulative steps vs
///     time).
///  3. We then test whether that sensor stream actually *predicts* the speed —
///     i.e. did the steps accumulate linearly over time (a steady, readable
///     gait)? That linearity is the R² of a steps-vs-time fit.
///  4. Only if it's predictive do we let the sensors move the dot afterwards;
///     otherwise we stay honest (advance at the measured average / wait for taps).
public struct CalibrationResult: Equatable {
    public let groundTruthSpeed: Double   // m/s  (distance ÷ time)
    public let strideLength: Double       // m/step (distance ÷ steps)
    public let predictability: Double     // R² of steps-vs-time, 0…1
    public let predictive: Bool           // passes the trust thresholds?
    public let stepCount: Int
    public let seconds: Double
}

public final class CalibrationAnalyzer {
    private var t0: Double?
    private var samples: [(t: Double, steps: Double)] = []

    public init() {}
    public func reset() { t0 = nil; samples = [] }

    /// Record the running step count at time `time` (seconds). Call each tick of
    /// the first leg.
    public func record(time: Double, cumulativeSteps: Int) {
        if t0 == nil { t0 = time }
        samples.append((time - (t0 ?? time), Double(cumulativeSteps)))
    }

    /// Compare the recorded sensor stream against the known leg distance.
    public func analyze(distanceM: Double, minSteps: Int = 8, minR2: Double = 0.80) -> CalibrationResult {
        let elapsed = samples.last?.t ?? 0
        let totalSteps = Int(samples.last?.steps ?? 0)
        let v = elapsed > 0 ? distanceM / elapsed : 0
        let stride = totalSteps > 0 ? distanceM / Double(totalSteps) : 0
        let r2 = linearityR2()
        // Trust the sensors only if enough steps fell in a steady (linear) cadence
        // and the implied stride is a plausible human one.
        let predictive = totalSteps >= minSteps && r2 >= minR2 && stride > 0.25 && stride < 1.5
        return CalibrationResult(groundTruthSpeed: v, strideLength: stride,
                                 predictability: r2, predictive: predictive,
                                 stepCount: totalSteps, seconds: elapsed)
    }

    /// R² of a least-squares line steps = a·t + b. 1 ⇒ perfectly steady gait.
    private func linearityR2() -> Double {
        let n = Double(samples.count)
        guard n >= 3 else { return 0 }
        let sx = samples.reduce(0) { $0 + $1.t }
        let sy = samples.reduce(0) { $0 + $1.steps }
        let sxx = samples.reduce(0) { $0 + $1.t * $1.t }
        let sxy = samples.reduce(0) { $0 + $1.t * $1.steps }
        let syy = samples.reduce(0) { $0 + $1.steps * $1.steps }
        let denom = n * sxx - sx * sx
        let ssTot = syy - sy * sy / n
        guard denom > 1e-9, ssTot > 1e-9 else { return 0 }   // no time spread or no step variation
        let a = (n * sxy - sx * sy) / denom
        let b = (sy - a * sx) / n
        var ssRes = 0.0
        for s in samples { let e = s.steps - (a * s.t + b); ssRes += e * e }
        return max(0, 1 - ssRes / ssTot)
    }
}
