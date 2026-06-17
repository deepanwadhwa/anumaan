import Foundation

// The "Guess Who" interrogation loop, lifted out of the iOS view model so it is a
// pure, headless decision core. It owns the question bank, picks the most useful
// question, applies a yes/no answer, and decides ask / lock / walk-more. It does
// NOT own sensing, the matchers, or any UI: the caller (the app, or the offline
// simulator) builds and scores a hypothesis cloud, then drives this session.
//
// Because the questions are plain predicates over a CURRENT position, a real
// person and the simulator's oracle answer them the same way: evaluate the
// predicate at the true location.

/// A live cloud of position hypotheses, viewed in CURRENT-position terms (where
/// the person is NOW, not where a walk started). Both the road/trail/driving
/// `RouteMatcher` and the off-trail `CurveMatcher` expose themselves this way via
/// the adapters below, so one interrogation loop drives either matcher.
public protocol HypothesisCloud: AnyObject {
    /// A weighted subsample of the surviving hypotheses (current position + a
    /// non-negative weight; weights need not sum to 1).
    func weightedSample(max n: Int) -> [(point: GeoPoint, weight: Double)]
    /// Fold in a yes/no answer: keep (or down-weight) hypotheses whose CURRENT
    /// position satisfies `keep`. `soft <= 0` removes them; otherwise multiplies
    /// the disagreeing ones by `soft`.
    func constrain(keep: (GeoPoint) -> Bool, soft: Double)
    /// The single leading current position (heaviest cluster), or nil if empty.
    func leadPosition() -> GeoPoint?
    /// Probability mass within `radiusM` of the lead, the lock metric (0...1).
    func concentration(radiusM: Double) -> Double
    /// Live current positions still in contention (for a map overlay).
    func livePositions() -> [GeoPoint]
}

/// Adapts the graph map-matcher (road / trail / driving). Its walkers are already
/// at the current position, so there is no walk offset to apply.
public final class RouteCloud: HypothesisCloud {
    public let matcher: RouteMatcher
    private let lockRadiusM: Double
    public init(_ matcher: RouteMatcher, lockRadiusM: Double = 120) {
        self.matcher = matcher; self.lockRadiusM = lockRadiusM
    }
    public func weightedSample(max n: Int) -> [(point: GeoPoint, weight: Double)] {
        matcher.weightedSample(max: n)
    }
    public func constrain(keep: (GeoPoint) -> Bool, soft: Double) {
        matcher.constrain(keep: keep, soft: soft)
    }
    public func leadPosition() -> GeoPoint? {
        matcher.summary(radiusM: lockRadiusM)?.estimate ?? matcher.estimate()
    }
    public func concentration(radiusM: Double) -> Double {
        matcher.summary(radiusM: radiusM)?.concentration ?? 0
    }
    public func livePositions() -> [GeoPoint] { matcher.livePositions }
}

/// Adapts the fixed-candidate curve matcher (off-trail / un-mapped trail). Its
/// candidates are walk STARTS, so `endOffset` (the walk's net displacement) is
/// added to read each one's CURRENT position.
public final class CurveCloud: HypothesisCloud {
    public let matcher: CurveMatcher
    public var endOffset: GeoPoint
    public init(_ matcher: CurveMatcher, endOffset: GeoPoint) {
        self.matcher = matcher; self.endOffset = endOffset
    }
    private func cur(_ p: GeoPoint) -> GeoPoint { GeoPoint(x: p.x + endOffset.x, y: p.y + endOffset.y) }
    public func weightedSample(max n: Int) -> [(point: GeoPoint, weight: Double)] {
        let cs = matcher.candidates, ws = matcher.weight
        let stepN = Swift.max(1, cs.count / Swift.max(1, n))
        return Swift.stride(from: 0, to: cs.count, by: stepN).compactMap { i in
            ws[i] > 0 ? (point: cur(cs[i]), weight: ws[i]) : nil
        }
    }
    public func constrain(keep: (GeoPoint) -> Bool, soft: Double) {
        matcher.constrain(endOffset: endOffset, hard: soft <= 0, keep: keep)
    }
    public func leadPosition() -> GeoPoint? { cur(matcher.lead) }
    public func concentration(radiusM: Double) -> Double { matcher.leadConcentration(radiusM: radiusM) }
    public func livePositions() -> [GeoPoint] { matcher.live().map(cur) }
}

/// The map data the interrogation needs, decoupled from the iOS `Atlas` so the
/// question loop is pure and testable. All geometry is in the local meter frame.
public struct InterrogationMap {
    public let features: FeatureField
    public let dem: DEMProvider
    public let landmarks: [(p: GeoPoint, kind: String)]                         // intersection / stop_sign / traffic_light
    public let namedRoads: [(name: String, segments: [(GeoPoint, GeoPoint)])]
    public let pois: [(name: String, p: GeoPoint)]

    public init(features: FeatureField, dem: DEMProvider,
                landmarks: [(p: GeoPoint, kind: String)] = [],
                namedRoads: [(name: String, segments: [(GeoPoint, GeoPoint)])] = [],
                pois: [(name: String, p: GeoPoint)] = []) {
        self.features = features; self.dem = dem
        self.landmarks = landmarks; self.namedRoads = namedRoads; self.pois = pois
    }
}

/// A yes/no question plus the predicate that decides it at a CURRENT position. The
/// predicate is the ground truth: a person standing at `p` answers `predicate(p)`,
/// which is exactly how the offline simulator's oracle answers too.
public struct RecoveryQuestion {
    public let text: String
    public let named: Bool
    public let predicate: (GeoPoint) -> Bool
    public init(text: String, named: Bool = false, predicate: @escaping (GeoPoint) -> Bool) {
        self.text = text; self.named = named; self.predicate = predicate
    }
}

/// The headless interrogation state machine. Construct it once with the area's
/// map data, then for each fresh round call `startRound`, feed answers with
/// `answer`, and render the returned `Outcome`.
public final class RecoverySession {
    public struct Config {
        public var lockRadiusM = 120.0
        public var lockConc = 0.80        // a 69% lock was once 3.5 km wrong, so hold a high bar
        public var cloudSample = 800      // hypotheses sampled to score a question's split
        public init() {}
    }

    public enum Outcome {
        case ask(RecoveryQuestion)                                    // put this to the person
        case located(point: GeoPoint, confident: Bool, concentration: Double)
        case needWalk                                                 // no lead yet, walk more
    }

    private let map: InterrogationMap
    public var config: Config
    private var askedTexts: Set<String> = []
    public private(set) var active: RecoveryQuestion?
    private var natureMode = false
    private var heading: Double?

    public init(map: InterrogationMap, config: Config = Config()) {
        self.map = map; self.config = config
    }

    // MARK: drive

    /// Begin a FRESH round over `cloud` (clears prior answers and context). The
    /// first question is always asked: we never lock straight off a walk or prune.
    public func startRound(cloud: HypothesisCloud, natureMode: Bool, heading: Double?) -> Outcome {
        self.natureMode = natureMode; self.heading = heading
        askedTexts.removeAll(); active = nil
        return decide(cloud: cloud)
    }

    /// Apply the person's yes/no to the active question, prune the cloud, decide.
    /// A "no" to a named road prunes it hard; generic answers prune softly.
    public func answer(_ yes: Bool, cloud: HypothesisCloud) -> Outcome {
        guard let q = active else { return decide(cloud: cloud) }
        let keep: (GeoPoint) -> Bool = { q.predicate($0) == yes }
        cloud.constrain(keep: keep, soft: q.named ? 0.02 : 0.2)
        active = nil
        return decide(cloud: cloud)
    }

    /// "Can't tell": drop the active question and decide with what we have.
    public func skip(cloud: HypothesisCloud) -> Outcome {
        active = nil
        return decide(cloud: cloud)
    }

    /// Clear all interrogation state (e.g. when the user restarts recovery).
    public func reset() { askedTexts.removeAll(); active = nil }

    /// Return the full question bank — named roads near the current lead + all generic
    /// questions — without running the interactive loop. Used by the sim to pre-evaluate
    /// every question at every hypothesis so the browser can run Q&A interactively.
    public func buildFullQuestionBank(cloud: HypothesisCloud) -> [RecoveryQuestion] {
        let lead = cloud.leadPosition()
        var qs: [RecoveryQuestion] = []
        qs.append(contentsOf: namedQuestions(lead: lead))
        qs.append(contentsOf: questionBank())
        var seen = Set<String>()
        return qs.filter { seen.insert($0.text).inserted }
    }

    // MARK: the decision

    private func decide(cloud: HypothesisCloud) -> Outcome {
        // Once at least one answer is in and the cloud agrees strongly on one spot,
        // lock there instead of asking more. Confirming an intersection ("yes,
        // Creekway Rd" then "yes, the cross street") collapses the cloud onto that
        // one junction, and that pin should END the questions, not start a round.
        if !askedTexts.isEmpty, let est = cloud.leadPosition() {
            let conc = cloud.concentration(radiusM: config.lockRadiusM)
            if conc >= config.lockConc { return .located(point: est, confident: true, concentration: conc) }
        }
        if let q = nextQuestion(cloud: cloud) {
            active = q; askedTexts.insert(q.text)
            return .ask(q)
        }
        // Out of useful questions: give the best answer rather than silence. A
        // confident lock if the cloud agrees, otherwise a "likely here" best guess.
        guard let est = cloud.leadPosition() else { return .needWalk }
        let conc = cloud.concentration(radiusM: config.lockRadiusM)
        return .located(point: est, confident: conc >= config.lockConc, concentration: conc)
    }

    /// The most useful unanswered question about the predicted spot: a lead-specific
    /// named landmark first ("Are you on <road>?"), then the best generic splitter
    /// over the cloud, then any generic feature actually TRUE at the lead. nil when
    /// there is nothing left worth asking.
    private func nextQuestion(cloud: HypothesisCloud) -> RecoveryQuestion? {
        let lead = cloud.leadPosition()
        if let q = namedQuestions(lead: lead).first(where: { !askedTexts.contains($0.text) }) { return q }
        let bank = questionBank().filter { !askedTexts.contains($0.text) }
        guard !bank.isEmpty else { return nil }
        let sample = cloud.weightedSample(max: config.cloudSample)
        if !sample.isEmpty {
            var total = 0.0
            var yes = [Double](repeating: 0, count: bank.count)
            for c in sample {
                total += c.weight
                for (b, q) in bank.enumerated() where q.predicate(c.point) { yes[b] += c.weight }
            }
            if let idx = CloudQuiz.bestSplitIndex(yesWeights: yes, total: total) { return bank[idx] }
        }
        // Nothing splits: still confirm any feature the predicted spot actually has.
        if let lead, let q = bank.first(where: { $0.predicate(lead) }) { return q }
        return nil
    }

    // MARK: question bank

    /// The yes/no questions available now (only those whose data we have).
    /// Predicates are evaluated at a hypothesis's CURRENT position.
    private func questionBank() -> [RecoveryQuestion] {
        var bank: [RecoveryQuestion] = []
        let ff = map.features
        func near(_ kinds: Set<MapFeature.Kind>, _ within: Double) -> (GeoPoint) -> Bool {
            { (ff.nearest(kinds, to: $0)?.distance ?? .greatestFiniteMagnitude) <= within }
        }
        // Tight proximity (~20-25 m = "right next to you"), so answers are precise.
        bank.append(.init(text: "Is there water (a lake, pond, or stream) right next to you — within ~25 m?",
                          predicate: near([.water, .waterway], 25)))
        bank.append(.init(text: "Are you in, or at the very edge of, woods/forest?",
                          predicate: near([.wood], 20)))
        bank.append(.init(text: "Are you standing in an open meadow or grassy field?",
                          predicate: near([.meadow, .grass], 25)))
        if natureMode {
            bank.append(.init(text: "Is there a marsh or wetland right next to you?",
                              predicate: near([.wetland], 25)))
            bank.append(.init(text: "Are you in, or beside, a park / open recreation area?",
                              predicate: near([.park], 30)))
        }
        if let h = heading {
            bank.append(.init(text: "Is there a stream or river within a few steps on your RIGHT?",
                              predicate: { ff.onSide([.waterway], from: $0, heading: h, within: 30, side: .right) }))
            bank.append(.init(text: "Is there a stream or river within a few steps on your LEFT?",
                              predicate: { ff.onSide([.waterway], from: $0, heading: h, within: 30, side: .left) }))
        }
        // Terrain shape — free from the DEM, no map tags needed.
        let dem = map.dem
        bank.append(.init(text: "Are you on noticeably STEEP ground (a real effort to climb straight up)?",
                          predicate: { (dem.slopeAspect(at: $0)?.slopeDeg ?? 0) >= 12 }))
        // Road landmarks ONLY make sense on a road / in a car — never on a trail.
        let roadLandmarks = natureMode ? [] : map.landmarks
        if !roadLandmarks.isEmpty {
            bank.append(.init(text: "Are you right at a road junction / intersection (within ~25 m)?",
                              predicate: landmarkNear("intersection", 25)))
            if roadLandmarks.contains(where: { $0.kind == "stop_sign" }) {
                bank.append(.init(text: "Is there a STOP sign within a few steps of you?",
                                  predicate: landmarkNear("stop_sign", 25)))
            }
            if roadLandmarks.contains(where: { $0.kind == "traffic_light" }) {
                bank.append(.init(text: "Is there a traffic light within a few steps of you?",
                                  predicate: landmarkNear("traffic_light", 25)))
            }
            if roadLandmarks.contains(where: { $0.kind == "dead_end" }) {
                bank.append(.init(text: "Are you at a dead end — the road just stops and doesn't continue?",
                                  predicate: landmarkNear("dead_end", 35)))
            }
        }
        return bank
    }

    private func landmarkNear(_ kind: String, _ within: Double) -> (GeoPoint) -> Bool {
        let r2 = within * within
        let lms = map.landmarks
        return { here in
            for lm in lms where lm.kind == kind {
                let dx = lm.p.x - here.x, dy = lm.p.y - here.y
                if dx * dx + dy * dy <= r2 { return true }
            }
            return false
        }
    }

    /// Verifiable questions about NAMED features near the current best guess.
    /// Roads/POIs on streets; trails/peaks in nature mode.
    private func namedQuestions(lead here: GeoPoint?) -> [RecoveryQuestion] {
        guard let here else { return [] }
        if natureMode { return natureNamedQuestions(here) }
        var out: [RecoveryQuestion] = []

        var roadCands: [(name: String, dist: Double, segs: [(GeoPoint, GeoPoint)])] = []
        for road in map.namedRoads {
            var dmin = Double.greatestFiniteMagnitude
            for s in road.segments { dmin = Swift.min(dmin, Geo.pointToSegment(here, s.0, s.1).0); if dmin < 5 { break } }
            if dmin < 90 { roadCands.append((road.name, dmin, road.segments)) }
        }
        for rc in roadCands.sorted(by: { $0.dist < $1.dist }).prefix(3) {
            let segs = rc.segs
            out.append(.init(text: "Are you on, or right beside, \(rc.name)?", named: true, predicate: { p in
                for s in segs where Geo.pointToSegment(p, s.0, s.1).0 <= 25 { return true }
                return false
            }))
        }
        let near = map.pois.filter { hypot($0.p.x - here.x, $0.p.y - here.y) < 130 }
            .sorted { hypot($0.p.x - here.x, $0.p.y - here.y) < hypot($1.p.x - here.x, $1.p.y - here.y) }
        for poi in near.prefix(3) {
            let p = poi.p
            out.append(.init(text: "Do you see \(poi.name) near you?", named: true, predicate: { q in
                hypot(p.x - q.x, p.y - q.y) <= 45
            }))
        }
        return out
    }

    /// Trail/off-trail named questions: NAMED TRAILS and PEAKS near the guess.
    private func natureNamedQuestions(_ here: GeoPoint) -> [RecoveryQuestion] {
        var out: [RecoveryQuestion] = []
        let feats = map.features.features
        var trails: [(name: String, dist: Double, pts: [GeoPoint])] = []
        for f in feats where f.kind == .trail && f.points.count >= 2 {
            guard let nm = f.name, !nm.isEmpty else { continue }
            var dmin = Double.greatestFiniteMagnitude
            for i in 1..<f.points.count { dmin = Swift.min(dmin, Geo.pointToSegment(here, f.points[i - 1], f.points[i]).0) }
            if dmin < 120 { trails.append((nm, dmin, f.points)) }
        }
        for tc in trails.sorted(by: { $0.dist < $1.dist }).prefix(2) {
            let pts = tc.pts
            out.append(.init(text: "Are you on, or beside, the \(tc.name) trail?", named: true, predicate: { p in
                for i in 1..<pts.count where Geo.pointToSegment(p, pts[i - 1], pts[i]).0 <= 30 { return true }
                return false
            }))
        }
        var peaks: [(name: String, dist: Double, p: GeoPoint)] = []
        for f in feats where f.kind == .peak {
            guard let nm = f.name, !nm.isEmpty, let p = f.points.first else { continue }
            let d = hypot(p.x - here.x, p.y - here.y)
            if d < 800 { peaks.append((nm, d, p)) }
        }
        for pk in peaks.sorted(by: { $0.dist < $1.dist }).prefix(2) {
            let p = pk.p
            out.append(.init(text: "Can you see \(pk.name) (a named hilltop) nearby?", named: true, predicate: { q in
                hypot(p.x - q.x, p.y - q.y) <= 250
            }))
        }
        return out
    }
}
