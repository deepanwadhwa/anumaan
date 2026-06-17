import Foundation
import CoreLocation
import Combine
import UIKit
import AnumaanCore

/// "Track Back": mark your trailhead, walk your hike while the app dead-reckons a
/// breadcrumb trail (heading + step distance), then "Take me back" guides you to
/// the start with a compass arrow. No localization guessing — we KNOW the start,
/// so this works even in featureless woods where "I'm Lost" can't. Drift is the
/// only error; over a there-and-back it stays recoverable, and the drawn trail
/// lets you retrace your exact path if you'd rather.
@MainActor
final class TrackViewModel: ObservableObject {
    enum Mode { case idle, tracking, returning }
    @Published var mode: Mode = .idle
    @Published var status = "Stand at your trailhead or car, center the map on it, then tap “Start here”."
    @Published var crumbs: [CLLocationCoordinate2D] = []   // breadcrumb trail (for the map)
    @Published var startPin: CLLocationCoordinate2D?
    @Published var here: CLLocationCoordinate2D?           // current dead-reckoned position
    @Published var center = CLLocationCoordinate2D(latitude: 34.6834, longitude: -82.8374)
    @Published var recenter = 0
    @Published var follow = false
    @Published var distFromStart = 0.0                     // straight-line metres to the start
    @Published var distWalked = 0.0                        // total metres walked
    @Published var elevFromStart = 0.0                     // barometer Δ vs the start
    @Published var backBearingTrue = 0.0                   // world bearing from here → start (0 = N)
    @Published var liveHeading = 0.0                       // device true heading
    @Published var coverageRects: [[CLLocationCoordinate2D]] = []

    let sensing = SensingService()
    private var cancellables = Set<AnyCancellable>()
    private var pos = GeoPoint(x: 0, y: 0)                 // metres from the start
    private var pathM: [GeoPoint] = []                     // breadcrumb path in metres (for retrace)
    private var lastCrumb = GeoPoint(x: 0, y: 0)
    private var lastDist = 0.0
    private var lastTickWall: Date?           // suspension-gap detector (see tick())
    private var startAlt = 0.0
    private var headingOffset = 0.0
    private var startLat = 0.0, startLon = 0.0
    private let mLat = 111_320.0
    private var stride = 0.75
    private var timer: Timer?
    private var visible: (s: Double, w: Double, n: Double, e: Double)?

    init() {
        sensing.start()
        sensing.$state
            .throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in guard let self else { return }; self.liveHeading = $0.headingDeg + self.headingOffset }
            .store(in: &cancellables)
        let s = UserDefaults.standard.double(forKey: "gaitStride")
        if s > 0.3 && s < 1.2 { stride = s }
        // Show any downloaded coverage so the user can frame their trailhead on real map.
        Task { [weak self] in
            if let a = await Atlas.build() { guard let self else { return }
                self.coverageRects = a.coverage.map { b in
                    [.init(latitude: b.s, longitude: b.w), .init(latitude: b.s, longitude: b.e),
                     .init(latitude: b.n, longitude: b.e), .init(latitude: b.n, longitude: b.w), .init(latitude: b.s, longitude: b.w)]
                }
                self.center = a.center; self.recenter += 1
            }
        }
    }

    func regionChanged(s: Double, w: Double, n: Double, e: Double) { visible = (s, w, n, e) }
    func tapStart(_ c: CLLocationCoordinate2D) { if mode == .idle { center = c; recenter += 1; startPin = c } }

    /// Mark the trailhead (map center, or wherever you tapped) and start tracking.
    func start() {
        let c = startPin ?? center
        startLat = c.latitude; startLon = c.longitude
        startPin = c; here = c; pos = .init(x: 0, y: 0); lastCrumb = pos; crumbs = [c]; pathM = [pos]
        headingOffset = GeoMagnetism.declination(latDeg: c.latitude, lonDeg: c.longitude, year: AppTime.decimalYear())
        sensing.declinationOffset = headingOffset
        sensing.resetLeg(); startAlt = sensing.altitudeM; lastDist = 0
        distWalked = 0; distFromStart = 0; elevFromStart = 0
        mode = .tracking; follow = true
        status = "Tracking from your start — walk your hike, I’m dropping breadcrumbs."
        DebugLog.shared.sessionStart("track", owner: sensing)
        DebugLog.shared.log("track.start", ["lat": c.latitude, "lon": c.longitude])
        center = c; recenter += 1
        beginTick()
    }

    func takeMeBack() {
        guard mode == .tracking else { return }
        mode = .returning; follow = true
        DebugLog.shared.log("track.back", ["walked": distWalked, "distFromStart": distFromStart])
        status = "Head back — follow the arrow to your start. The distance counts down as you walk."
    }

    func stop() {
        timer?.invalidate(); timer = nil; mode = .idle; follow = false
        UIApplication.shared.isIdleTimerDisabled = false
        sensing.stopBackgroundKeepAlive()
        DebugLog.shared.log("track.stop", ["walked": distWalked])
        status = "Stopped. Stand at a new start and tap “Start here” to track again."
    }

    private func beginTick() {
        lastTickWall = nil
        // Keep awake + alive so a screen-lock can't suspend us and break the
        // breadcrumb trail (the path that guides you home).
        UIApplication.shared.isIdleTimerDisabled = true
        sensing.startBackgroundKeepAlive()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func latLon(_ p: GeoPoint) -> CLLocationCoordinate2D {
        .init(latitude: startLat + p.y / mLat,
              longitude: startLon + p.x / (mLat * cos(startLat * .pi / 180)))
    }

    private func tick() {
        let d = sensing.hasPedometerDistance ? sensing.legDistanceM : Double(sensing.legSteps) * stride
        // Suspension guard: a big wall-clock gap means the app was asleep and
        // CoreMotion went dark, while the pedometer back-filled its distance. That
        // catch-up has no heading behind it — integrating it would teleport the
        // breadcrumb in a straight line. Re-baseline so the lost distance is
        // dropped (the trail keeps a small gap instead of a fabricated jump).
        let now = Date()
        if let last = lastTickWall, now.timeIntervalSince(last) > 3.0 {
            lastDist = d
            status = "⚠️ The phone slept — part of your trail wasn’t recorded. Keep the app open and screen on."
        }
        lastTickWall = now
        let dd = d - lastDist
        if dd > 0.05 {                                    // advance the breadcrumb path
            lastDist = d
            let h = (sensing.state.headingDeg + headingOffset) * .pi / 180
            pos = GeoPoint(x: pos.x + sin(h) * dd, y: pos.y + cos(h) * dd)
            here = latLon(pos)
            if pos.distance(to: lastCrumb) >= 5 { lastCrumb = pos; crumbs.append(here!); pathM.append(pos) }
        }
        distWalked = d
        elevFromStart = sensing.altitudeM - startAlt
        if mode == .returning {
            // RETRACE the breadcrumb path in reverse. We point to a breadcrumb ~20 m
            // back along your route, not a beeline to the start. Both your position
            // and the breadcrumb live in the SAME dead-reckoned frame, so even though
            // absolute drift accumulates, the LOCAL bearing to the next breadcrumb is
            // right — you walk your own footsteps home.
            guard pathM.count >= 2 else { return }
            var ni = 0, bestD = Double.greatestFiniteMagnitude
            for (i, p) in pathM.enumerated() { let dd = p.distance(to: pos); if dd < bestD { bestD = dd; ni = i } }
            var ti = ni, acc = 0.0
            while ti > 0 && acc < 20 { acc += pathM[ti].distance(to: pathM[ti - 1]); ti -= 1 }
            let target = pathM[ti]
            var b = atan2(target.x - pos.x, target.y - pos.y) * 180 / .pi
            if b < 0 { b += 360 }
            backBearingTrue = b
            var rem = 0.0
            for i in Swift.stride(from: ni, to: 0, by: -1) { rem += pathM[i].distance(to: pathM[i - 1]) }
            distFromStart = rem                                 // metres still to walk back along your route
            center = here ?? center
            status = (ni <= 1 && pos.distance(to: pathM[0]) < 15)
                ? "You’re basically back — look around for your trailhead / car!"
                : String(format: "Retrace home: %.0f m of your path left. Walk where the arrow points.", rem)
            DebugLog.shared.log("track.tick", ["rem": rem, "ni": ni, "elev": elevFromStart])
        } else {
            distFromStart = (pos.x * pos.x + pos.y * pos.y).squareRoot()
            var b = atan2(-pos.x, -pos.y) * 180 / .pi
            if b < 0 { b += 360 }
            backBearingTrue = b
            status = String(format: "Tracking — %.0f m walked · %.0f m from start · %+.0f m elevation.",
                            distWalked, distFromStart, elevFromStart)
        }
    }
}
