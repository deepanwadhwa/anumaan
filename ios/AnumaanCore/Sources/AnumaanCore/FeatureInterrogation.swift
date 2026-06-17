import Foundation

/// Picks the most *discriminating* feature question to ask the lost person when
/// the cloud is down to a few candidate clusters — exactly the kind of clue the
/// user described: "is there a stream on your right, open water nearby, woods?"
/// Each question is computed from the `FeatureField`, so the answer prunes the
/// ghosts whose surroundings disagree.
/// "Guess Who" over the particle cloud: given how much probability weight answers
/// YES to each candidate question, pick the question that splits the cloud closest
/// to 50/50 — the single most informative thing to ask next. Works on a broad
/// cloud (thousands of hypotheses), not just a 2-3 cluster tie-break, so questions
/// can carry the search in flat terrain where elevation alone never narrows.
public enum CloudQuiz {
    public static func bestSplitIndex(yesWeights: [Double], total: Double,
                                      band: ClosedRange<Double> = 0.18...0.82) -> Int? {
        guard total > 0 else { return nil }
        var best: (idx: Int, dist: Double)?
        for (i, yw) in yesWeights.enumerated() {
            let frac = yw / total
            guard band.contains(frac) else { continue }
            let d = abs(frac - 0.5)
            if best == nil || d < best!.dist { best = (i, d) }
        }
        return best?.idx
    }
}

public enum FeatureInterrogation {
    public struct Question: Equatable {
        public enum Mode: Equatable { case onSide(Side); case near }
        public let text: String
        public let kinds: Set<MapFeature.Kind>
        public let mode: Mode
        public let heading: Double
        public let within: Double

        /// Does this clue hold at point `p` per the feature data?
        public func holds(at p: GeoPoint, field: FeatureField) -> Bool {
            switch mode {
            case .onSide(let side):
                return field.onSide(kinds, from: p, heading: heading, within: within, side: side)
            case .near:
                return (field.nearest(kinds, to: p)?.distance ?? .greatestFiniteMagnitude) <= within
            }
        }
    }

    /// The walked `heading` orients the left/right questions. Returns the question
    /// that best splits the candidates, or nil if none separates them.
    public static func bestQuestion(field: FeatureField, candidates: [GeoPoint],
                                    heading: Double) -> Question? {
        guard candidates.count >= 2 else { return nil }
        let bank: [Question] = [
            .init(text: "Is there a stream or river on your right?", kinds: [.waterway],
                  mode: .onSide(.right), heading: heading, within: 90),
            .init(text: "Is there a stream or river on your left?", kinds: [.waterway],
                  mode: .onSide(.left), heading: heading, within: 90),
            .init(text: "Can you see open water — a lake or pond — nearby?", kinds: [.water],
                  mode: .near, heading: heading, within: 160),
            .init(text: "Are you in or right at the edge of woods/forest?", kinds: [.wood],
                  mode: .near, heading: heading, within: 45),
            .init(text: "Is there an open meadow or grass field nearby?", kinds: [.meadow, .grass],
                  mode: .near, heading: heading, within: 110),
        ]
        var best: (score: Int, q: Question)?
        for q in bank {
            let yes = candidates.filter { q.holds(at: $0, field: field) }.count
            let split = min(yes, candidates.count - yes)
            if split >= 1, best == nil || split > best!.score { best = (split, q) }
        }
        return best?.q
    }
}
