import Foundation
import CoreLocation
import MapLibre

/// Downloads the **basemap** (street/contour vector tiles + glyphs + sprite) for
/// a bbox into MapLibre's native offline cache, so the map renders with no
/// connectivity. Uses `MLNOfflineStorage` tile-pyramid packs — once a region is
/// cached, any `MLNMapView` on the same style serves it offline automatically.
final class OfflineBasemap {
    static let shared = OfflineBasemap()

    /// (fractionComplete 0…1, finished) — called on the main thread.
    var onProgress: ((Double, Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []

    private init() { observeOnce() }

    func download(styleURL: URL, south: Double, west: Double, north: Double, east: Double,
                  minZoom: Double, maxZoom: Double, name: String) {
        let bounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: south, longitude: west),
            ne: CLLocationCoordinate2D(latitude: north, longitude: east))
        let region = MLNTilePyramidOfflineRegion(styleURL: styleURL, bounds: bounds,
                                                  fromZoomLevel: minZoom, toZoomLevel: maxZoom)
        let context = (try? NSKeyedArchiver.archivedData(
            withRootObject: ["name": name], requiringSecureCoding: false)) ?? Data()
        MLNOfflineStorage.shared.addPack(for: region, withContext: context) { pack, _ in
            pack?.resume()
        }
    }

    private func observeOnce() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .MLNOfflinePackProgressChanged, object: nil,
                                        queue: .main) { [weak self] note in
            guard let pack = note.object as? MLNOfflinePack else { return }
            let p = pack.progress
            let frac = p.countOfResourcesExpected > 0
                ? Double(p.countOfResourcesCompleted) / Double(p.countOfResourcesExpected) : 0
            self?.onProgress?(frac, pack.state == .complete)
        })
    }
}
