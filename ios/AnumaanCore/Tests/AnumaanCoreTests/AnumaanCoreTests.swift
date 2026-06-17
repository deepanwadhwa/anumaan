import XCTest
@testable import AnumaanCore

final class AnumaanCoreTests: XCTestCase {

    private func simpleRoute() -> [Milestone] {
        [Milestone(id: "o", type: "origin", distanceFromPrior: 0, name: "Origin"),
         Milestone(id: "a", type: "stop_sign", distanceFromPrior: 100, name: "A"),
         Milestone(id: "b", type: "intersection", distanceFromPrior: 200, name: "B"),
         Milestone(id: "c", type: "destination", distanceFromPrior: 300, name: "Dest")]
    }
    private func engine(speed: Double = 10) -> NavigationEngine {
        NavigationEngine(route: simpleRoute(), estimatedSpeed: speed, startTime: 0)
    }

    // Rule 1 — expected time
    func testExpectedTime() {
        XCTAssertEqual(engine(speed: 10).expectedTime(), 10, accuracy: 1e-9)
    }

    // Dead reckoning + fallback
    func testTickAccumulatesThenFallback() {
        let e = engine(speed: 10)
        XCTAssertNil(e.tick(now: 5, isStationary: false, isMoving: true))
        XCTAssertEqual(e.accumulatedDistance, 50, accuracy: 1e-9)
        let ev = e.tick(now: 10, isStationary: false, isMoving: true)
        XCTAssertEqual(ev?.kind, .fallbackPrompt)
        XCTAssertEqual(ev?.milestone.id, "a")
    }

    // Rule 4 — speed smoothing
    func testSmoothingSlowerLeg() {
        let e = engine(speed: 10)
        e.tick(now: 10, isStationary: false, isMoving: true)
        let v = e.confirmArrival(now: 20)        // leg "took" 20 s ⇒ V_true 5
        XCTAssertEqual(v, 5, accuracy: 1e-9)
        XCTAssertEqual(e.estimatedSpeed, 8.5, accuracy: 1e-9)   // 10*.7 + 5*.3
        XCTAssertEqual(e.currentIndex, 2)
    }
    func testSmoothingFasterLeg() {
        let e = engine(speed: 10)
        e.tick(now: 10, isStationary: false, isMoving: true)
        let v = e.confirmArrival(now: 5)         // V_true 20
        XCTAssertEqual(v, 20, accuracy: 1e-9)
        XCTAssertEqual(e.estimatedSpeed, 13, accuracy: 1e-9)    // 10*.7 + 20*.3
    }

    // Hard gate — holds at the node, never glides past
    func testCarHoldsAtNodeUntilConfirmed() {
        let e = engine(speed: 10)
        for i in 1..<40 { e.tick(now: Double(i), isStationary: false, isMoving: true) }
        XCTAssertEqual(e.accumulatedDistance, 100, accuracy: 1e-9)
        XCTAssertEqual(e.remainingDistance(), 0, accuracy: 1e-9)
        XCTAssertEqual(e.currentIndex, 1)
        e.confirmArrival(now: 40)
        XCTAssertEqual(e.currentIndex, 2)
    }

    // No telemetry ⇒ never snaps, never moves, never corrupts speed
    func testNoTelemetryNeverSnapsOrExplodes() {
        let route = [Milestone(id: "o", type: "origin", distanceFromPrior: 0),
                     Milestone(id: "a", type: "stop_sign", distanceFromPrior: 30, name: "A"),
                     Milestone(id: "b", type: "destination", distanceFromPrior: 300, name: "Dest")]
        let e = NavigationEngine(route: route, estimatedSpeed: 11, startTime: 0)
        var t = 0.0
        for _ in 0..<400 {
            t += 0.05
            XCTAssertNil(e.tick(now: t, isStationary: false, isMoving: false))
        }
        XCTAssertEqual(e.currentIndex, 1)
        XCTAssertEqual(e.accumulatedDistance, 0)
        XCTAssertEqual(e.estimatedSpeed, 11)
    }

    // Short leg must not insta-snap before the minimum leg time
    func testShortLegNoInstaSnap() {
        let route = [Milestone(id: "o", type: "origin", distanceFromPrior: 0),
                     Milestone(id: "a", type: "stop_sign", distanceFromPrior: 30, name: "A"),
                     Milestone(id: "b", type: "destination", distanceFromPrior: 300, name: "Dest")]
        let e = NavigationEngine(route: route, estimatedSpeed: 11, startTime: 0)
        XCTAssertNil(e.tick(now: 1, isStationary: true, isMoving: false))   // too soon
        XCTAssertEqual(e.currentIndex, 1)
        let ev = e.tick(now: 4, isStationary: true, isMoving: false)        // ≥ min leg
        XCTAssertEqual(ev?.kind, .autoSnap)
        XCTAssertLessThanOrEqual(e.estimatedSpeed, 45)
    }

    // Turn geometry
    func testTurnGeometry() {
        let right = Turn.turnAngle(prev: (0, 0), node: (0.001, 0), next: (0.001, 0.001))
        XCTAssertTrue(right > 80 && right < 100)
        XCTAssertEqual(Turn.classify(right), "right")
        let left = Turn.turnAngle(prev: (0, 0), node: (0.001, 0), next: (0.001, -0.001))
        XCTAssertTrue(left < -80 && left > -100)
        XCTAssertEqual(Turn.classify(left), "left")
        let straight = Turn.turnAngle(prev: (0, 0), node: (0.001, 0), next: (0.002, 0.00001))
        XCTAssertEqual(Turn.classify(straight), "straight")
    }

    // Heading calibration recovers the constant mounting offset
    func testCalibrationRecoversOffset() {
        let cal = HeadingCalibration(alpha: 0.1, minSamples: 20)
        let leg = 30.0, mount = 110.0
        for _ in 0..<60 { cal.add(compassDeg: Turn.wrap360(leg + mount), legBearingDeg: leg) }
        XCTAssertTrue(cal.calibrated)
        XCTAssertLessThan(abs(Turn.angleDiff(cal.offset, mount)), 3)
        XCTAssertLessThan(abs(Turn.angleDiff(cal.trueHeading(compassDeg: 230), 120)), 3)
    }
    func testCalibrationWrapsNorth() {
        let cal = HeadingCalibration(alpha: 0.1, minSamples: 20)
        for _ in 0..<60 { cal.add(compassDeg: 10, legBearingDeg: 350) }   // offset 20°
        XCTAssertTrue(cal.calibrated)
        XCTAssertLessThan(abs(Turn.angleDiff(cal.offset, 20)), 3)
    }

    // Tilt compass tracks a 90° horizontal rotation
    func testTiltCompassTracksRotation() {
        let g = (0.0, 0.0, 9.8)
        let ha = Fusion.tiltCompensatedHeading(accel: g, mag: (20, 0, -40))
        let hb = Fusion.tiltCompensatedHeading(accel: g, mag: (0, 20, -40))
        XCTAssertTrue(abs(Turn.angleDiff(hb, ha)) > 80 && abs(Turn.angleDiff(hb, ha)) < 100)
    }
}
