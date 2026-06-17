import Foundation
import AnumaanCore

// CLI-only helpers: oracle interrogation loop (prints to stdout) and percentage formatter.
// The shared sim utilities (LCG, synthesizeWalk, runMatcher, etc.) live in AnumaanCore/SimHelpers.swift.

func pctStr(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

/// Drive the headless RecoverySession with an oracle that answers each question
/// from the TRUE location, and print the transcript plus the final localization error.
func runInterrogation(matcher: RouteMatcher, map: InterrogationMap, trueEnd: GeoPoint,
                      heading: Double?, latLon: ((GeoPoint) -> (lat: Double, lon: Double))? = nil) {
    if let wl = matcher.summary(radiusM: 120) {
        print("After the walk alone: \(matcher.walkerCount) hypotheses, ~\(wl.areas) candidate areas, "
            + "lead concentration \(pctStr(wl.concentration)), lead error \(String(format: "%.0f", wl.estimate.distance(to: trueEnd))) m.")
    }
    let session = RecoverySession(map: map)
    let cloud = RouteCloud(matcher)
    print("Interrogation (the oracle answers each question from the TRUE location):")
    var outcome = session.startRound(cloud: cloud, natureMode: false, heading: heading)
    var asked = 0
    loop: while asked < 16 {
        switch outcome {
        case .ask(let q):
            asked += 1
            let yes = q.predicate(trueEnd)
            print("  Q\(asked): \(q.text)  ->  \(yes ? "YES" : "no")")
            outcome = session.answer(yes, cloud: cloud)
        case .located(let p, let confident, let conc):
            var loc = ""
            if let latLon { let ll = latLon(p); loc = String(format: " (%.5f, %.5f)", ll.lat, ll.lon) }
            print("  => LOCATED (\(confident ? "confident" : "tentative"), \(pctStr(conc)) of the cloud)\(loc). "
                + "Error vs truth: \(String(format: "%.1f", p.distance(to: trueEnd))) m")
            break loop
        case .needWalk:
            print("  => no lead yet — would ask for a longer, curvier walk.")
            break loop
        }
    }
    if asked >= 16 { print("  => stopped after \(asked) questions (safety cap).") }
}
