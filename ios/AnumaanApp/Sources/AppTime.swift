import Foundation

enum AppTime {
    /// Current date as a decimal year (e.g. 2026.42) for the WMM.
    static func decimalYear() -> Double {
        let now = Date(), cal = Calendar(identifier: .gregorian)
        let y = cal.component(.year, from: now)
        guard let start = cal.date(from: DateComponents(year: y, month: 1, day: 1)),
              let next = cal.date(from: DateComponents(year: y + 1, month: 1, day: 1)) else { return Double(y) }
        return Double(y) + now.timeIntervalSince(start) / next.timeIntervalSince(start)
    }
}
