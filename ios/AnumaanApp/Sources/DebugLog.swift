import Foundation
import CoreLocation
import Combine

/// Field recorder for debugging. When on, it streams everything to a JSONL file
/// in Documents: throttled sensor samples (heading raw+true, altitude, steps,
/// cadence, moving, activity), **GPS ground-truth** (for evaluating how far off
/// the GPS-free estimate was), and tagged events from navigation/recovery. Pull
/// the file off the phone via Finder (file sharing) or the Share button, then
/// hand it over for analysis.
final class DebugLog: NSObject, ObservableObject {
    static let shared = DebugLog()

    @Published private(set) var recording = false
    @Published private(set) var lineCount = 0
    @Published private(set) var currentName = ""
    /// When on (default), every navigation/recovery session auto-records — so you
    /// can't forget to flip a switch before walking out the door.
    @Published var autoRecord = true { didSet { UserDefaults.standard.set(autoRecord, forKey: "dbgAutoRecord") } }

    override init() {
        super.init()
        if let v = UserDefaults.standard.object(forKey: "dbgAutoRecord") as? Bool { autoRecord = v }
    }

    /// Called at the start of a nav/recover session: begins recording automatically.
    /// `owner` is the SensingService that drives THIS session — only its sensor
    /// stream is logged, so multiple live SensingService instances (Nav + Recover)
    /// don't interleave two pedometer baselines into one jittery `steps` series.
    func sessionStart(_ tag: String, owner: AnyObject? = nil) {
        sensorOwner = owner.map(ObjectIdentifier.init)
        if autoRecord && !recording { start() }
        log("session", ["tag": tag])
    }
    private var sensorOwner: ObjectIdentifier?

    private let q = DispatchQueue(label: "anumaan.debuglog")
    private var handle: FileHandle?
    private var url: URL?
    private let loc = CLLocationManager()
    private var lastSensorLog = 0.0
    private let sensorPeriod = 0.33          // ~3 Hz sensor sampling
    private var lastMotionLog = 0.0
    private let motionPeriod = 0.04          // ~25 Hz raw-motion sampling (enough to see gait)

    private static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("debuglogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func start() {
        guard !recording else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "anumaan-\(stamp).jsonl"
        let u = Self.dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: u.path, contents: nil)
        handle = try? FileHandle(forWritingTo: u)
        url = u; currentName = name; lineCount = 0; recording = true
        q.async { [weak self] in self?.lineCountRaw = 0; self?.pendingLines = 0 }
        log("meta", ["app": "Anumaan", "startedISO": ISO8601DateFormatter().string(from: Date())])
        loc.delegate = self
        loc.desiredAccuracy = kCLLocationAccuracyBest
        loc.requestWhenInUseAuthorization()
        loc.startUpdatingLocation()
    }

    func stop() {
        guard recording else { return }
        log("meta", ["stopped": true])
        loc.stopUpdatingLocation()
        q.sync { try? handle?.close(); handle = nil }
        recording = false
    }

    /// Append one JSONL record. Safe to call from any thread.
    func log(_ kind: String, _ fields: [String: Any]) {
        guard recording || kind == "meta" else { return }
        var obj = fields
        obj["k"] = kind
        obj["t"] = Date().timeIntervalSince1970
        q.async { [weak self] in
            guard let self, let h = self.handle,
                  let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
            h.write(data); h.write(Data([0x0A]))
            self.pendingLines += 1
            // Batch the @Published update — at 25 Hz, bumping it per-record churned
            // SwiftUI on the main thread. Surface the count ~2×/sec instead.
            if self.pendingLines >= 12 {
                let total = self.lineCountRaw + self.pendingLines
                self.lineCountRaw = total; self.pendingLines = 0
                DispatchQueue.main.async { self.lineCount = total }
            }
        }
    }
    private var pendingLines = 0          // accessed only on `q`
    private var lineCountRaw = 0          // accessed only on `q`

    /// Throttled sensor sample (called from the sensing loop at 50 Hz).
    /// `motion` carries the raw device-motion vectors (userAccel, gravity, attitude)
    /// so we can reconstruct the TRUE direction of travel offline — independent of how
    /// the phone is held — instead of trusting the compass pointing direction.
    func sensor(owner: AnyObject? = nil, time: Double, headingRaw: Double, headingTrue: Double, altitude: Double,
                steps: Int, cadence: Double, stationary: Bool, hasMag: Bool, yaw: Double = 0, rotZ: Double = 0,
                motion: [String: Double]? = nil) {
        guard recording, time - lastSensorLog >= sensorPeriod else { return }
        // Only the session-owning sensing instance logs (avoids two pedometers
        // interleaving into one jittery step series).
        if let sensorOwner, let owner, ObjectIdentifier(owner) != sensorOwner { return }
        lastSensorLog = time
        // yaw = gyro/attitude yaw (deg); rotZ = raw gyro rate (deg/s). Logged so we
        // can rebuild a pure-gyro heading offline and A/B it vs the compass heading.
        var obj: [String: Any] = ["hdgRaw": headingRaw, "hdgTrue": headingTrue, "alt": altitude,
                                  "steps": steps, "cad": cadence, "stat": stationary, "mag": hasMag,
                                  "yaw": yaw, "rotZ": rotZ]
        if let motion { for (k, v) in motion { obj[k] = v } }
        log("sensor", obj)
    }

    /// High-rate ("mot") raw-motion sample (~25 Hz) for reconstructing the TRUE
    /// direction of travel offline, independent of phone orientation: userAccel
    /// (device frame) + attitude quaternion (rotates it into x=north,z=up world).
    func motion(owner: AnyObject? = nil, time: Double,
                uax: Double, uay: Double, uaz: Double, gx: Double, gy: Double, gz: Double,
                qw: Double, qx: Double, qy: Double, qz: Double) {
        guard recording, time - lastMotionLog >= motionPeriod else { return }
        if let sensorOwner, let owner, ObjectIdentifier(owner) != sensorOwner { return }
        lastMotionLog = time
        log("mot", ["uax": uax, "uay": uay, "uaz": uaz, "gx": gx, "gy": gy, "gz": gz,
                    "qw": qw, "qx": qx, "qy": qy, "qz": qz])
    }

    func logs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
    }
    func clear() { for u in logs() { try? FileManager.default.removeItem(at: u) }; lineCount = 0; currentName = "" }
}

extension DebugLog: CLLocationManagerDelegate {
    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { return }
        log("gps", ["lat": l.coordinate.latitude, "lon": l.coordinate.longitude,
                    "acc": l.horizontalAccuracy, "alt": l.altitude, "spd": l.speed,
                    "course": l.course])
    }
}
