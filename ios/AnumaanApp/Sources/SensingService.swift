import Foundation
import CoreMotion
import CoreLocation
import Combine
import AnumaanCore

/// Reads CoreMotion (Apple's fused IMU) and produces a `MotionState` for the
/// navigation engine. CoreMotion already fuses accel+gyro+mag into a stable
/// heading and gravity-separated `userAcceleration`, so we only keep the
/// decision logic (moving/stopped hysteresis, per-leg heading change).
///
/// NOTE: the stop/go thresholds below are for gravity-removed acceleration
/// (≈0 at rest) and WILL need tuning on a real drive — they're a starting point.
public final class SensingService: ObservableObject {
    @Published public private(set) var state = MotionState()
    @Published public private(set) var available = false
    /// Relative altitude (m) from the barometer, low-pass filtered ("Pocket Rule"
    /// — smooth gait bounce, keep macro terrain slope). 0 at the start of updates.
    @Published public private(set) var altitudeM = 0.0
    @Published public private(set) var hasBarometer = false
    /// True if the user denied Motion & Fitness — then steps/activity/altitude all
    /// silently return nothing, so we surface it.
    @Published public private(set) var motionDenied = false
    /// Magnetic→true offset (WMM declination) for the loaded area, set by the view
    /// model so the debug log can record both raw and true heading.
    public var declinationOffset = 0.0

    private let altimeter = CMAltimeter()
    private var altLpf = 0.0
    private var altPrimed = false

    private let manager = CMMotionManager()
    // Serial queue: CoreMotion must not deliver updates concurrently, or the
    // rolling `window` array races and corrupts memory (EXC_BAD_ACCESS).
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "anumaan.sensing"
        return q
    }()

    // moving/stopped hysteresis
    private var window: [Double] = []
    private var belowSince: Double?
    private var aboveSince: Double?
    private var yawEma = 0.0
    private var stationary = false
    private var headingRef: Double?

    // Step counting via CMPedometer — Apple's trained, offline step detector.
    // (A hand-rolled accel peak counter was unreliable; this is rock-solid.)
    private let pedometer = CMPedometer()
    @Published public private(set) var hasPedometer = false
    private var pedTotalSteps = 0
    private var legStepBaseline = 0
    private var pedCadence = 0.0                 // steps/sec, from the pedometer
    public var legSteps: Int { max(0, pedTotalSteps - legStepBaseline) }
    public var totalSteps: Int { pedTotalSteps }
    // Distance straight from CMPedometer — Apple's model adapts stride to PACE, so
    // it tracks walking AND running (a fixed 0.75 m/step under-measures a run).
    private var pedTotalDistance = 0.0
    private var legDistanceBaseline = 0.0
    public private(set) var hasPedometerDistance = false
    public var legDistanceM: Double { max(0, pedTotalDistance - legDistanceBaseline) }

    // Apple's on-device activity classifier (stationary/walking/automotive/…).
    private let activityMgr = CMMotionActivityManager()
    private var activityStationary: Bool?   // nil = no confident reading yet
    private var activityDriving = false
    private var activityWalking = false

    // Fallback (when activity is unknown): accelerometer-variance hysteresis on
    // gravity-removed accel. Thresholds raised so a tap/jiggle doesn't register;
    // motion must be sustained (movingHold) to count.
    private let stationaryThreshold = 0.004
    private let movingThreshold = 0.025
    private let movingHold = 1.2

    // Keep-alive only. iOS suspends a foreground app when the screen locks / phone
    // pockets, which kills the CoreMotion heading stream mid-walk (the pedometer
    // then back-fills steps, fabricating a fake straight leg). Running Location in
    // the background keeps the process scheduled so device-motion keeps streaming.
    // NOTE: these fixes are NEVER read by the navigation/recovery algorithm — this
    // manager exists solely to stop iOS from putting us to sleep.
    private let keepAlive = CLLocationManager()
    public func startBackgroundKeepAlive() {
        keepAlive.requestWhenInUseAuthorization()
        keepAlive.desiredAccuracy = kCLLocationAccuracyThreeKilometers   // coarse — unused
        keepAlive.distanceFilter = 100
        keepAlive.pausesLocationUpdatesAutomatically = false
        keepAlive.allowsBackgroundLocationUpdates = true                 // requires UIBackgroundModes: location
        keepAlive.startUpdatingLocation()
    }
    public func stopBackgroundKeepAlive() {
        keepAlive.allowsBackgroundLocationUpdates = false
        keepAlive.stopUpdatingLocation()
    }

    public init() {}

    public func start() {
        guard manager.isDeviceMotionAvailable else { available = false; return }
        available = true
        let auth = CMMotionActivityManager.authorizationStatus()
        motionDenied = (auth == .denied || auth == .restricted)
        manager.deviceMotionUpdateInterval = 1.0 / 50.0
        manager.showsDeviceMovementDisplay = true   // shows the compass-calibration prompt
        manager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical,
                                         to: queue) { [weak self] dm, _ in
            guard let self, let dm else { return }
            self.process(dm)
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            hasBarometer = true
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                let raw = data.relativeAltitude.doubleValue        // meters since start
                // Light smoothing only — the barometer is pressure-derived (no gait
                // bounce), so a heavy filter just lags/attenuates a real climb.
                self.altLpf = self.altPrimed ? 0.6 * self.altLpf + 0.4 * raw : raw
                self.altPrimed = true
                self.altitudeM = self.altLpf
            }
        }
        if CMPedometer.isStepCountingAvailable() {
            hasPedometer = true
            pedometer.startUpdates(from: Date()) { [weak self] data, _ in
                guard let self, let data else { return }
                DispatchQueue.main.async {
                    self.pedTotalSteps = data.numberOfSteps.intValue
                    if let c = data.currentCadence?.doubleValue { self.pedCadence = c }
                    if let d = data.distance?.doubleValue { self.pedTotalDistance = d; self.hasPedometerDistance = true }
                }
            }
        }
        if CMMotionActivityManager.isActivityAvailable() {
            activityMgr.startActivityUpdates(to: .main) { [weak self] act in
                guard let self, let act, act.confidence != .low else { return }
                self.activityStationary = act.stationary
                self.activityDriving = act.automotive || act.cycling
                self.activityWalking = act.walking || act.running
            }
        }
    }

    public func stop() {
        manager.stopDeviceMotionUpdates()
        activityMgr.stopActivityUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        pedometer.stopUpdates()
    }

    /// Re-baseline per-leg counters (call when a node is confirmed).
    public func resetLeg() {
        headingRef = state.headingDeg; legStepBaseline = pedTotalSteps; legDistanceBaseline = pedTotalDistance
    }

    private func process(_ dm: CMDeviceMotion) {
        let now = dm.timestamp
        let ua = dm.userAcceleration
        let mag = (ua.x * ua.x + ua.y * ua.y + ua.z * ua.z).squareRoot()
        window.append(mag)
        if window.count > Fusion.windowSamples { window.removeFirst() }
        let variance = self.variance()

        let cadence = pedCadence                     // steps/sec from CMPedometer

        let yawDps = dm.rotationRate.z * 180 / .pi   // yaw about vertical (z-up frame)
        yawEma = 0.8 * yawEma + 0.2 * yawDps
        let rotating = abs(yawEma) > Fusion.rotationMovingDps

        // Variance hysteresis (fallback): sustained vibration ⇒ moving.
        belowSince = variance < stationaryThreshold ? (belowSince ?? now) : nil
        aboveSince = variance > movingThreshold ? (aboveSince ?? now) : nil
        if stationary {
            let moved = aboveSince.map { now - $0 >= movingHold } ?? false
            if moved || rotating { stationary = false }
        } else {
            if let b = belowSince, now - b >= Fusion.stationaryHold, !rotating { stationary = true }
        }

        // Decide moving/stopped from Apple's classifier:
        //  • driving → trust the classifier's stop/go (cruising has ~0 accel
        //    variance, so the walking variance test would wrongly say "stopped");
        //  • walking → use the responsive accel-variance hysteresis;
        //  • otherwise (truly stationary / no reading) → hold.
        let isStationary: Bool
        if let st = activityStationary {
            if activityDriving       { isStationary = st }
            else if activityWalking  { isStationary = stationary }
            else                     { isStationary = st }
        } else {
            isStationary = true
        }

        let heading = dm.heading >= 0 ? dm.heading : 0          // CoreMotion fused heading
        if headingRef == nil { headingRef = heading }
        let headingChange = Turn.angleDiff(heading, headingRef ?? heading)

        let s = MotionState(isStationary: isStationary, isMoving: !isStationary,
                            headingDeg: heading, headingChangeDeg: headingChange,
                            yawRateDps: yawEma, cadence: cadence,
                            hasGyro: true, hasMag: dm.heading >= 0)
        DispatchQueue.main.async { self.state = s }

        DebugLog.shared.sensor(owner: self, time: now, headingRaw: heading,
                               headingTrue: heading + declinationOffset, altitude: altitudeM,
                               steps: legSteps, cadence: cadence, stationary: isStationary,
                               hasMag: dm.heading >= 0,
                               yaw: dm.attitude.yaw * 180 / .pi, rotZ: yawDps)
        // High-rate raw motion (own stream, ~25 Hz) for reconstructing the TRUE
        // travel direction offline regardless of how the phone is held. The attitude
        // QUATERNION (xMagneticNorthZVertical: x=north, z=up) rotates userAccel into
        // the world frame exactly.
        let q = dm.attitude.quaternion
        DebugLog.shared.motion(owner: self, time: now,
                               uax: ua.x, uay: ua.y, uaz: ua.z,
                               gx: dm.gravity.x, gy: dm.gravity.y, gz: dm.gravity.z,
                               qw: q.w, qx: q.x, qy: q.y, qz: q.z)
    }

    private func variance() -> Double {
        let n = window.count
        if n < 2 { return 0 }
        let m = window.reduce(0, +) / Double(n)
        return window.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(n)
    }
}
