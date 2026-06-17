import Foundation

/// DEM-based skyline test for the tie-breaker interrogations. "Is the horizon
/// blocked by a ridge looking <direction>?" becomes: sample the elevation along
/// that bearing and find the maximum upward angle to the skyline — if it clears a
/// threshold, a ridge blocks the view. This is the *physics* the spec trusts
/// (the DEM's shape), not a semantic map tag.
public enum Horizon {
    public static let eyeHeightM = 1.7

    /// Maximum elevation angle (degrees) of the skyline along `headingDeg`.
    public static func maxElevationAngle(dem: DEMProvider, from: GeoPoint, headingDeg: Double,
                                         rangeM: Double = 4000, step: Double = 60) -> Double {
        let prof = dem.profile(from: from, headingDeg: headingDeg, length: rangeM, step: step)
        guard prof.count >= 2 else { return 0 }
        var maxAng = -90.0
        for i in 1..<prof.count {
            let ang = atan2(prof[i] - eyeHeightM, Double(i) * step) * 180 / .pi
            if ang > maxAng { maxAng = ang }
        }
        return maxAng
    }

    /// Does a ridge block the horizon along this bearing?
    public static func ridgeBlocked(dem: DEMProvider, from: GeoPoint, headingDeg: Double,
                                    rangeM: Double = 4000, step: Double = 60,
                                    thresholdDeg: Double = 2.5) -> Bool {
        maxElevationAngle(dem: dem, from: from, headingDeg: headingDeg, rangeM: rangeM, step: step) >= thresholdDeg
    }
}

/// Chooses the most *discriminating* visual question to ask the human when the
/// particle filter is down to a few candidate clusters — the compass bearing on
/// which the candidates most disagree about a blocked horizon.
public enum Interrogation {
    public struct Question: Equatable {
        public let headingDeg: Double
        public let direction: String       // "West", "NE", …
        public let rangeM: Double
        public let step: Double
        public let thresholdDeg: Double
    }

    static let compass: [(Double, String)] = [
        (0, "North"), (45, "NE"), (90, "East"), (135, "SE"),
        (180, "South"), (225, "SW"), (270, "West"), (315, "NW"),
    ]

    public static func name(forHeading h: Double) -> String {
        let i = Int(((h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 45).rounded()) % 8
        return compass[i].1
    }

    /// Best splitting question, or nil if no bearing separates the candidates.
    public static func bestQuestion(dem: DEMProvider, candidates: [GeoPoint],
                                    rangeM: Double = 4000, step: Double = 60,
                                    thresholdDeg: Double = 2.5) -> Question? {
        guard candidates.count >= 2 else { return nil }
        var best: (score: Int, heading: Double, name: String)?
        for (h, nm) in compass {
            let blocked = candidates.map {
                Horizon.ridgeBlocked(dem: dem, from: $0, headingDeg: h,
                                     rangeM: rangeM, step: step, thresholdDeg: thresholdDeg)
            }
            let yes = blocked.filter { $0 }.count
            let split = min(yes, blocked.count - yes)      // balanced split ⇒ best discriminator
            if split >= 1, best == nil || split > best!.score {
                best = (split, h, nm)
            }
        }
        guard let b = best else { return nil }
        return Question(headingDeg: b.heading, direction: b.name,
                        rangeM: rangeM, step: step, thresholdDeg: thresholdDeg)
    }
}
