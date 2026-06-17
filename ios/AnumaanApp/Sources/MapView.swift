import SwiftUI
import UIKit
import CoreLocation
import MapLibre

/// MapLibre map: a real street basemap + route line + home/start/dest pins + a
/// live vehicle marker, with tap-to-set-point, free pan/zoom, search recenter,
/// and a region callback (so we can download exactly what's on screen).
///
/// Basemap defaults to OpenFreeMap "Liberty" — a free, no-key vector street map
/// (online). The offline Protomaps PMTiles basemap drops in as a different style.
struct MapView: UIViewRepresentable {
    var center: CLLocationCoordinate2D
    var recenterTrigger: Int = 0
    var recenterZoom: Double = 12
    var follow: Bool = false
    var routeCoords: [CLLocationCoordinate2D] = []
    var vehicle: CLLocationCoordinate2D?
    var nextMilestone: CLLocationCoordinate2D?
    var ghosts: [CLLocationCoordinate2D] = []        // recovery particle cloud
    var candidates: [CLLocationCoordinate2D] = []    // recovery tie-break candidates
    var coverageRects: [[CLLocationCoordinate2D]] = []  // outlines of downloaded offline areas
    var plannedRects: [[CLLocationCoordinate2D]] = []   // queued chunks not yet downloaded
    var home: CLLocationCoordinate2D?
    var start: CLLocationCoordinate2D?
    var dest: CLLocationCoordinate2D?
    var onTap: ((CLLocationCoordinate2D) -> Void)?
    var onRegion: ((_ s: Double, _ w: Double, _ n: Double, _ e: Double) -> Void)?
    var styleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero)
        map.styleURL = styleURL
        map.delegate = context.coordinator
        map.setCenter(center, zoomLevel: recenterZoom, animated: false)
        map.addGestureRecognizer(UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleTap(_:))))
        context.coordinator.map = map
        context.coordinator.lastRecenter = recenterTrigger
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let co = context.coordinator
        co.parent = self
        if co.lastRecenter != recenterTrigger {       // search pressed → recenter
            co.lastRecenter = recenterTrigger
            map.setCenter(center, zoomLevel: recenterZoom, animated: true)
        }
        co.syncCoverage(coverageRects)
        co.syncPlanned(plannedRects)
        co.syncRoute(routeCoords)
        co.syncPin(\.homeAnno, coord: home, title: "Home")
        co.syncPin(\.startAnno, coord: start, title: "Start")
        co.syncPin(\.destAnno, coord: dest, title: "Destination")
        co.syncPin(\.nextAnno, coord: nextMilestone, title: "Next")
        co.syncShape(co.ghostSource, ghosts, pending: \.pendingGhosts)
        co.syncShape(co.candidateSource, candidates, pending: \.pendingCandidates)
        co.syncVehicle(vehicle)
        // Follow the dot, but ONLY when it has actually moved — otherwise a held
        // dot re-centers on every refresh and fights the user's pan.
        if follow, let v = vehicle {
            let moved = co.lastFollowed.map {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                    .distance(from: CLLocation(latitude: v.latitude, longitude: v.longitude)) > 4
            } ?? true
            if moved {
                if co.lastFollowed == nil { map.setCenter(v, zoomLevel: 16, animated: true) }
                else { map.setCenter(v, animated: true) }
                co.lastFollowed = v
            }
        } else {
            co.lastFollowed = nil
        }
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: MapView
        weak var map: MLNMapView?
        var lastRecenter = -1
        var lastFollowed: CLLocationCoordinate2D?
        var routeLine: MLNPolyline?
        var coverageLines: [MLNPolyline] = []      // downloaded-area outlines (drawn green)
        var coverageKey = ""
        var plannedLines: [MLNPolyline] = []       // queued chunks (drawn orange)
        var plannedKey = ""
        var vehicleAnno: MLNPointAnnotation?
        var homeAnno: MLNPointAnnotation?
        var startAnno: MLNPointAnnotation?
        var destAnno: MLNPointAnnotation?
        var nextAnno: MLNPointAnnotation?

        // Recovery overlays: many points → GeoJSON shape source + circle layer
        // (far cheaper than thousands of annotation views).
        var ghostSource: MLNShapeSource?
        var candidateSource: MLNShapeSource?
        var pendingGhosts: [CLLocationCoordinate2D] = []
        var pendingCandidates: [CLLocationCoordinate2D] = []

        init(_ parent: MapView) { self.parent = parent }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            if ghostSource == nil {
                ghostSource = addCircleLayer(style, id: "ghosts", radius: 2.5,
                                             color: UIColor.systemTeal.withAlphaComponent(0.45))
            }
            if candidateSource == nil {
                candidateSource = addCircleLayer(style, id: "candidates", radius: 7,
                                                 color: UIColor.systemOrange)
            }
            setShape(ghostSource, pendingGhosts)
            setShape(candidateSource, pendingCandidates)
        }

        private func addCircleLayer(_ style: MLNStyle, id: String, radius: Double, color: UIColor) -> MLNShapeSource {
            let src = MLNShapeSource(identifier: id, shape: nil, options: nil)
            style.addSource(src)
            let layer = MLNCircleStyleLayer(identifier: id + "-layer", source: src)
            layer.circleRadius = NSExpression(forConstantValue: radius)
            layer.circleColor = NSExpression(forConstantValue: color)
            layer.circleStrokeWidth = NSExpression(forConstantValue: id == "candidates" ? 2 : 0)
            layer.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
            style.addLayer(layer)
            return src
        }

        func syncShape(_ src: MLNShapeSource?, _ coords: [CLLocationCoordinate2D],
                       pending: ReferenceWritableKeyPath<Coordinator, [CLLocationCoordinate2D]>) {
            self[keyPath: pending] = coords      // remember until the style finishes loading
            setShape(src, coords)
        }

        private func setShape(_ src: MLNShapeSource?, _ coords: [CLLocationCoordinate2D]) {
            guard let src else { return }
            if coords.isEmpty { src.shape = nil; return }
            src.shape = MLNShapeCollectionFeature(shapes: coords.map {
                let f = MLNPointFeature(); f.coordinate = $0; return f
            })
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let map = map else { return }
            let c = map.convert(g.location(in: map), toCoordinateFrom: map)
            parent.onTap?(c)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            let b = mapView.visibleCoordinateBounds
            parent.onRegion?(b.sw.latitude, b.sw.longitude, b.ne.latitude, b.ne.longitude)
        }

        var routeKey = ""
        func syncRoute(_ coords: [CLLocationCoordinate2D]) {
            guard let map = map else { return }
            let key = coords.isEmpty ? "" :
                "\(coords.count)|\(coords.first!.latitude),\(coords.first!.longitude)|\(coords.last!.latitude),\(coords.last!.longitude)"
            if key == routeKey { return }           // unchanged → don't redraw (was flickering)
            routeKey = key
            if let old = routeLine { map.removeAnnotation(old); routeLine = nil }
            guard coords.count >= 2 else { return }
            var pts = coords
            let line = MLNPolyline(coordinates: &pts, count: UInt(pts.count))
            map.addAnnotation(line); routeLine = line
        }

        func syncCoverage(_ rects: [[CLLocationCoordinate2D]]) {
            guard let map = map else { return }
            let key = rects.map { "\($0.count):\($0.first?.latitude ?? 0),\($0.first?.longitude ?? 0)" }.joined(separator: "|")
            if key == coverageKey { return }
            coverageKey = key
            for old in coverageLines { map.removeAnnotation(old) }
            coverageLines = []
            for rect in rects where rect.count >= 2 {
                var pts = rect
                let line = MLNPolyline(coordinates: &pts, count: UInt(pts.count))
                map.addAnnotation(line); coverageLines.append(line)
            }
        }

        func syncPlanned(_ rects: [[CLLocationCoordinate2D]]) {
            guard let map = map else { return }
            let key = rects.map { "\($0.count):\($0.first?.latitude ?? 0),\($0.first?.longitude ?? 0)" }.joined(separator: "|")
            if key == plannedKey { return }
            plannedKey = key
            for old in plannedLines { map.removeAnnotation(old) }
            plannedLines = []
            for r in rects where r.count >= 2 {
                var pts = r
                let line = MLNPolyline(coordinates: &pts, count: UInt(pts.count))
                map.addAnnotation(line); plannedLines.append(line)
            }
        }

        func syncPin(_ key: ReferenceWritableKeyPath<Coordinator, MLNPointAnnotation?>,
                     coord: CLLocationCoordinate2D?, title: String) {
            guard let map = map else { return }
            if let coord = coord {
                if let a = self[keyPath: key] {           // move existing pin (no flicker)
                    if a.coordinate.latitude != coord.latitude || a.coordinate.longitude != coord.longitude {
                        a.coordinate = coord
                    }
                } else {
                    let a = MLNPointAnnotation(); a.coordinate = coord; a.title = title
                    map.addAnnotation(a); self[keyPath: key] = a
                }
            } else if let a = self[keyPath: key] {
                map.removeAnnotation(a); self[keyPath: key] = nil
            }
        }

        func syncVehicle(_ coord: CLLocationCoordinate2D?) {
            guard let map = map else { return }
            guard let coord = coord else {
                if let v = vehicleAnno { map.removeAnnotation(v); vehicleAnno = nil }; return
            }
            if let v = vehicleAnno { v.coordinate = coord }
            else { let a = MLNPointAnnotation(); a.coordinate = coord; a.title = "Car"
                   map.addAnnotation(a); vehicleAnno = a }
        }

        func mapView(_ m: MLNMapView, lineWidthForPolylineAnnotation a: MLNPolyline) -> CGFloat {
            (coverageLines.contains { $0 === a } || plannedLines.contains { $0 === a }) ? 2 : 5
        }
        func mapView(_ m: MLNMapView, strokeColorForShapeAnnotation a: MLNShape) -> UIColor {
            guard let l = a as? MLNPolyline else { return .systemBlue }
            if plannedLines.contains(where: { $0 === l }) { return UIColor.systemOrange.withAlphaComponent(0.9) }
            if coverageLines.contains(where: { $0 === l }) { return UIColor.systemGreen.withAlphaComponent(0.8) }
            return .systemBlue
        }
        func mapView(_ m: MLNMapView, alphaForShapeAnnotation a: MLNShape) -> CGFloat {
            guard let l = a as? MLNPolyline else { return 1 }
            return (coverageLines.contains { $0 === l } || plannedLines.contains { $0 === l }) ? 0.85 : 1
        }
        func mapView(_ m: MLNMapView, annotationCanShowCallout a: MLNAnnotation) -> Bool { true }

        // Distinct colored dots per role (car/next/start/dest/home) instead of
        // identical red pins.
        func mapView(_ m: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard let pt = annotation as? MLNPointAnnotation else { return nil }   // not the route line
            let title = pt.title ?? ""
            let id = "dot-\(title)"
            let view = m.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MLNAnnotationView(reuseIdentifier: id)
            let size: CGFloat = (title == "Car") ? 24 : 18
            view.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            view.layer.cornerRadius = size / 2
            view.layer.borderWidth = 2.5
            view.layer.borderColor = UIColor.white.cgColor
            view.layer.shadowColor = UIColor.black.cgColor
            view.layer.shadowOpacity = 0.3
            view.layer.shadowRadius = 2
            view.layer.shadowOffset = .init(width: 0, height: 1)
            switch title {
            case "Car":         view.backgroundColor = .systemBlue
            case "Next":        view.backgroundColor = .systemOrange
            case "Home":        view.backgroundColor = .systemPurple
            case "Start":       view.backgroundColor = .systemGreen
            case "Destination": view.backgroundColor = .systemRed
            default:            view.backgroundColor = .systemGray
            }
            return view
        }
    }
}
