import Foundation

public enum NavEventKind { case autoSnap, fallbackPrompt, destination }

public struct NavEvent {
    public let kind: NavEventKind
    public let milestone: Milestone
    public let expectedTime: Double
    public let elapsedTime: Double
    public let message: String
    public let automated: Bool
    public let vTrue: Double?
}

/// Deterministic navigation state machine (port of `anumaan/state_machine.py`).
///
/// Dead reckoning is gated on motion and hard-capped at the next node (the car
/// holds there until arrival is confirmed). Arrival is confirmed by a genuine
/// stop near the node, a manual tap, or — wired up a layer above — a detected
/// turn. Speed is smoothed 70/30 on each arrival.
public final class NavigationEngine {
    // Tunables (identical to the Python prototype).
    public static let snapRangeM = 50.0
    public static let minLegSeconds = 3.0
    public static let speedMin = 1.0
    public static let speedMax = 45.0
    public static let smoothRetain = 0.7
    public static let smoothObserve = 0.3

    public private(set) var route: [Milestone]
    public private(set) var currentIndex: Int
    public private(set) var estimatedSpeed: Double
    public private(set) var timeEnteredLeg: Double
    public private(set) var accumulatedDistance: Double
    public private(set) var velocityHistory: [Double] = []
    /// False until the first arrival is confirmed. While false the dot HOLDS at
    /// the start (we don't yet know the walker's pace) and the first confirmed
    /// arrival sets the speed outright (start→first-milestone distance ÷ time),
    /// instead of the usual 70/30 blend.
    public private(set) var calibrated: Bool
    private var lastTick: Double

    public init(route: [Milestone], estimatedSpeed: Double = 11.0, startTime: Double = 0,
                calibrated: Bool = true) {
        precondition(route.count >= 2, "route needs an origin and ≥1 milestone")
        self.route = route
        self.currentIndex = 1
        self.estimatedSpeed = estimatedSpeed
        self.timeEnteredLeg = startTime
        self.accumulatedDistance = 0
        self.calibrated = calibrated
        self.lastTick = startTime
    }

    /// Replace the working speed used for dead reckoning (e.g. with a live
    /// gait-predicted speed). Allowed down to 0 so a stopped walker holds.
    public func overrideSpeed(_ v: Double) {
        estimatedSpeed = min(Self.speedMax, max(0, v))
    }

    public var isComplete: Bool { currentIndex >= route.count }
    public var nextMilestone: Milestone { route[currentIndex] }
    public func expectedTime() -> Double { nextMilestone.distanceFromPrior / estimatedSpeed }
    public func remainingDistance() -> Double {
        max(0, nextMilestone.distanceFromPrior - accumulatedDistance)
    }
    public func withinSnapRange() -> Bool {
        nextMilestone.distanceFromPrior - accumulatedDistance <= Self.snapRangeM
    }

    /// Advance to time `now`. `isStationary` is a genuine stop (arms auto-snap);
    /// `isMoving` gates dead reckoning (false ⇒ hold, e.g. no fresh telemetry).
    @discardableResult
    public func tick(now: Double, isStationary: Bool, isMoving: Bool) -> NavEvent? {
        if isComplete { return nil }
        let dt = now - lastTick
        if dt < 0 { return nil }
        lastTick = now

        // Dead-reckon only once we know the walker's pace; before the first
        // calibration the dot holds at the start.
        if isMoving && calibrated { accumulatedDistance += estimatedSpeed * dt }
        // Hard milestone gate: never dead-reckon past the next node.
        accumulatedDistance = min(accumulatedDistance, nextMilestone.distanceFromPrior)

        let legElapsed = now - timeEnteredLeg
        if calibrated && isStationary && withinSnapRange() && legElapsed >= Self.minLegSeconds {
            let ms = nextMilestone
            let wasLast = currentIndex == route.count - 1
            let v = arrive(now: now)
            return NavEvent(kind: wasLast ? .destination : .autoSnap, milestone: ms,
                            expectedTime: ms.distanceFromPrior / max(estimatedSpeed, 1e-9),
                            elapsedTime: legElapsed,
                            message: "Auto-snapped arrival at \(ms.name.isEmpty ? ms.id : ms.name)",
                            automated: true, vTrue: v)
        }
        if accumulatedDistance >= nextMilestone.distanceFromPrior {
            let ms = nextMilestone
            let isLast = currentIndex == route.count - 1
            return NavEvent(kind: isLast ? .destination : .fallbackPrompt, milestone: ms,
                            expectedTime: expectedTime(), elapsedTime: legElapsed,
                            message: "Reached \(ms.name.isEmpty ? ms.id : ms.name)? confirm to continue",
                            automated: false, vTrue: nil)
        }
        return nil
    }

    /// Shared arrival handler: V_true, 70/30 smoothing (clamped), advance the leg.
    @discardableResult
    private func arrive(now: Double) -> Double {
        let ms = nextMilestone
        let tActual = max(now - timeEnteredLeg, Self.minLegSeconds)
        let vTrue = ms.distanceFromPrior / tActual
        // First calibration sets pace outright; later legs blend 70/30.
        let blended = calibrated ? estimatedSpeed * Self.smoothRetain + vTrue * Self.smoothObserve : vTrue
        estimatedSpeed = min(Self.speedMax, max(Self.speedMin, blended))
        calibrated = true
        velocityHistory.append(vTrue)
        currentIndex += 1
        timeEnteredLeg = now
        accumulatedDistance = 0
        lastTick = now
        return vTrue
    }

    /// Manual "I've arrived" / turn-confirm.
    @discardableResult
    public func confirmArrival(now: Double) -> Double {
        precondition(!isComplete, "route already complete")
        return arrive(now: now)
    }
}
