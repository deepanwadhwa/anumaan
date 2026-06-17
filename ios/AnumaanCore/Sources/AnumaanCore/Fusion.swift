import Foundation

/// Sensor fusion + heading calibration (port of `anumaan/fusion.py` + `sde.py`).
///
/// On iOS, CoreMotion already fuses accel+gyro+mag into a stable heading and
/// gravity-separated acceleration, so the app can feed those in directly. This
/// type keeps the same decision logic (moving/stopped hysteresis fused with
/// rotation; a complementary heading filter) for parity with the prototype and
/// as a fallback if CoreMotion's heading is noisy in a metal cabin.
public enum Fusion {
    // SDE hysteresis (re-tune for gravity-removed `userAcceleration` on-device).
    public static let windowSamples = 75
    public static let stationaryThreshold = 0.015
    public static let movingThreshold = 0.040
    public static let stationaryHold = 1.0
    public static let movingHold = 0.8
    public static let rotationMovingDps = 8.0
    public static let yawDeadbandDps = 2.0
    public static let gyroTrust = 0.92

    /// Tilt-compensated compass heading (deg, 0=N) from gravity + magnetic field.
    public static func tiltCompensatedHeading(accel: (Double, Double, Double),
                                              mag: (Double, Double, Double)) -> Double {
        let (ax, ay, az) = accel
        let (mx, my, mz) = mag
        let roll = atan2(ay, az)
        let pitch = atan2(-ax, (ay * ay + az * az).squareRoot() == 0 ? 1e-9
                          : (ay * ay + az * az).squareRoot())
        let cr = cos(roll), sr = sin(roll), cp = cos(pitch), sp = sin(pitch)
        let mxh = mx * cp + mz * sp
        let myh = mx * sr * sp + my * cr - mz * sr * cp
        return Turn.wrap360(atan2(-myh, mxh) * 180 / .pi)
    }
}

/// Estimates the constant phone→vehicle heading offset with no user prompt:
/// on a known-straight leg, true bearing == leg bearing, so the offset is
/// `compass − legBearing` (a circular EMA, wrap-safe). Port of `HeadingCalibration`.
public final class HeadingCalibration {
    private let alpha: Double
    private let minSamples: Int
    private var s = 0.0
    private var c = 0.0
    public private(set) var n = 0

    public init(alpha: Double = 0.03, minSamples: Int = 40) {
        self.alpha = alpha
        self.minSamples = minSamples
    }

    public func add(compassDeg: Double, legBearingDeg: Double) {
        let o = Turn.wrap360(compassDeg - legBearingDeg) * .pi / 180
        s = (1 - alpha) * s + alpha * sin(o)
        c = (1 - alpha) * c + alpha * cos(o)
        n += 1
    }

    public var calibrated: Bool { n >= minSamples && (s * s + c * c) > 1e-6 }
    public var offset: Double { Turn.wrap360(atan2(s, c) * 180 / .pi) }
    public func trueHeading(compassDeg: Double) -> Double { Turn.wrap360(compassDeg - offset) }
}
