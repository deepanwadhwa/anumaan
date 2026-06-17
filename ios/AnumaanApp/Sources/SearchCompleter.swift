import Foundation
import MapKit

/// Wraps MapKit's free, no-key autocomplete. Emits suggestion titles as you type;
/// resolving a pick gives a coordinate. No API key, works on-device.
final class SearchCompleter: NSObject, MKLocalSearchCompleterDelegate {
    var onResults: (([MKLocalSearchCompletion]) -> Void)?
    private let completer = MKLocalSearchCompleter()
    /// Area search wants cities/towns/regions only — not every street address.
    private var placesOnly = false

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func query(_ q: String, placesOnly: Bool = false) {
        let s = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.placesOnly != placesOnly {
            self.placesOnly = placesOnly
            completer.resultTypes = placesOnly ? [.address] : [.address, .pointOfInterest]
        }
        if s.count < 2 { onResults?([]); return }
        completer.queryFragment = s
    }

    func completerDidUpdateResults(_ c: MKLocalSearchCompleter) {
        guard placesOnly else { onResults?(c.results); return }
        // Cities/towns/regions read as words; street addresses & ZIPs carry digits.
        // Dropping any completion with a digit leaves place names (a coarse but
        // reliable filter, since MapKit has no "locality-only" result type).
        let places = c.results.filter {
            ($0.title + " " + $0.subtitle).rangeOfCharacter(from: .decimalDigits) == nil
        }
        onResults?(places)
    }
    func completer(_ c: MKLocalSearchCompleter, didFailWithError error: Error) { onResults?([]) }

    static func resolve(_ completion: MKLocalSearchCompletion) async -> CLLocationCoordinate2D? {
        let resp = try? await MKLocalSearch(request: .init(completion: completion)).start()
        return resp?.mapItems.first?.placemark.coordinate
    }
}
