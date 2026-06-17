import Foundation

/// A compact, information-dense store of the hiker-relevant map features (water,
/// streams, woods, meadows, wetland, peaks) in the recovery engine's local-meter
/// frame, built from decoded vector tiles. Supports the *relational* questions
/// the particle filter needs — "is there a stream on my right?", "am I in a
/// lake?", "where's the nearest water?" — so each feature becomes either an
/// automatic likelihood term or a human interrogation.
public struct MapFeature: Codable, Equatable {
    public enum Kind: String, Codable {
        case water, waterway, wood, grass, wetland, meadow, farmland, park, peak, trail, poi, other
    }
    public let kind: Kind
    public let isArea: Bool          // polygon (lake/wood) vs line (stream) vs point (peak)
    public let points: [GeoPoint]    // local meters: ring / polyline / single point
    public let name: String?

    public init(kind: Kind, isArea: Bool, points: [GeoPoint], name: String? = nil) {
        self.kind = kind; self.isArea = isArea; self.points = points; self.name = name
    }
}

public enum Side { case left, right }

public struct FeatureField: Codable {
    public let originLat: Double
    public let originLon: Double
    public let features: [MapFeature]

    public init(originLat: Double, originLon: Double, features: [MapFeature]) {
        self.originLat = originLat; self.originLon = originLon; self.features = features
    }

    private static let metersPerDegLat = 111_320.0
    public func meters(lat: Double, lon: Double) -> GeoPoint {
        GeoPoint(x: (lon - originLon) * Self.metersPerDegLat * cos(originLat * .pi / 180),
                 y: (lat - originLat) * Self.metersPerDegLat)
    }

    // MARK: relational queries

    /// Nearest feature of the given kinds: the feature, its distance (m), and the
    /// compass bearing (0 = N) from `p` to the closest point on it.
    public func nearest(_ kinds: Set<MapFeature.Kind>, to p: GeoPoint)
        -> (feature: MapFeature, distance: Double, bearing: Double)? {
        var best: (MapFeature, Double, GeoPoint)?
        for f in features where kinds.contains(f.kind) {
            let (d, c) = Geo.distance(from: p, toFeaturePoints: f.points)
            if best == nil || d < best!.1 { best = (f, d, c) }
        }
        guard let b = best else { return nil }
        return (b.0, b.1, Geo.bearing(from: p, to: b.2))
    }

    /// Is there such a feature within `within` m, on the requested side of `heading`?
    public func onSide(_ kinds: Set<MapFeature.Kind>, from p: GeoPoint, heading: Double,
                       within: Double, side: Side) -> Bool {
        guard let n = nearest(kinds, to: p), n.distance <= within else { return false }
        let rel = Turn.angleDiff(n.bearing, heading)   // + = clockwise (right) of heading
        return side == .right ? rel > 10 : rel < -10
    }

    /// The area feature (e.g. a lake) that contains `p`, if any — used to mask
    /// impossible ghost positions out of water.
    public func containing(_ kinds: Set<MapFeature.Kind>, point p: GeoPoint) -> MapFeature? {
        for f in features where f.isArea && kinds.contains(f.kind) {
            if Geo.pointInPolygon(p, f.points) { return f }
        }
        return nil
    }

    // MARK: build from decoded vector tiles

    /// Convert decoded MVT tiles into a local-meter feature field. Only the
    /// hiker-relevant OpenMapTiles layers are kept (water/waterway/landcover/
    /// landuse/park/mountain_peak); everything else is dropped — dense by design.
    public static func fromMVT(tiles: [(tile: MVT.Tile, z: Int, x: Int, y: Int)],
                               originLat: Double, originLon: Double) -> FeatureField {
        let mPerLat = metersPerDegLat, cosLat = cos(originLat * .pi / 180)
        func toMeters(_ pt: (x: Int32, y: Int32), _ z: Int, _ x: Int, _ y: Int, _ extent: Int) -> GeoPoint {
            let ll = TileMath.tileToLonLat(z: z, x: x, y: y, tx: Double(pt.x), ty: Double(pt.y), extent: Double(extent))
            return GeoPoint(x: (ll.lon - originLon) * mPerLat * cosLat, y: (ll.lat - originLat) * mPerLat)
        }
        var feats: [MapFeature] = []
        for t in tiles {
            for layer in t.tile.layers {
                for f in layer.features {
                    guard let (kind, isArea) = classify(layer: layer.name, f.properties) else { continue }
                    let name = f.properties["name"]?.string
                    if kind == .poi, name?.isEmpty != false { continue }   // keep only NAMED POIs
                    if f.geomType == 1 {                          // points (peaks)
                        for ring in f.rings { for pt in ring {
                            feats.append(MapFeature(kind: kind, isArea: false,
                                points: [toMeters(pt, t.z, t.x, t.y, layer.extent)], name: name))
                        } }
                    } else {                                       // lines / polygons
                        for ring in f.rings where ring.count >= 2 {
                            feats.append(MapFeature(kind: kind, isArea: isArea,
                                points: ring.map { toMeters($0, t.z, t.x, t.y, layer.extent) }, name: name))
                        }
                    }
                }
            }
        }
        return FeatureField(originLat: originLat, originLon: originLon, features: feats)
    }

    private static func classify(layer: String, _ props: [String: MVT.Value]) -> (MapFeature.Kind, Bool)? {
        let cls = props["class"]?.string ?? props["subclass"]?.string ?? ""
        switch layer {
        case "water":         return (.water, true)
        case "waterway":      return (.waterway, false)
        case "mountain_peak": return (.peak, false)
        case "park":          return (.park, true)
        case "poi":           return (.poi, false)        // shops/amenities (named, point)
        case "transportation":
            // Non-drivable ways = trails (drivable roads come from the routing graph).
            switch cls {
            case "path", "footway", "track", "bridleway", "steps", "cycleway", "pedestrian":
                return (.trail, false)
            default: return nil
            }
        case "landcover":
            switch cls {
            case "wood", "forest", "tree": return (.wood, true)
            case "grass", "grassland":     return (.grass, true)
            case "wetland", "swamp", "bog", "marsh", "mangrove": return (.wetland, true)
            case "farmland":               return (.farmland, true)
            default: return nil
            }
        case "landuse":
            switch cls {
            case "meadow":                              return (.meadow, true)
            case "farmland", "farm", "orchard":         return (.farmland, true)
            case "grass", "village_green", "recreation_ground": return (.grass, true)
            case "wood", "forest":                      return (.wood, true)
            default: return nil
            }
        default: return nil
        }
    }
}

/// Planar geometry helpers (local meters).
public enum Geo {
    /// Compass bearing 0…360, 0 = north (+y), 90 = east (+x).
    public static func bearing(from a: GeoPoint, to b: GeoPoint) -> Double {
        let deg = atan2(b.x - a.x, b.y - a.y) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Distance from `p` to a feature (point / polyline / ring) + the closest point.
    public static func distance(from p: GeoPoint, toFeaturePoints pts: [GeoPoint]) -> (Double, GeoPoint) {
        guard let first = pts.first else { return (.greatestFiniteMagnitude, p) }
        if pts.count == 1 { return (p.distance(to: first), first) }
        var best = Double.greatestFiniteMagnitude, bestPt = first
        for i in 1..<pts.count {
            let (d, c) = pointToSegment(p, pts[i - 1], pts[i])
            if d < best { best = d; bestPt = c }
        }
        return (best, bestPt)
    }

    public static func pointToSegment(_ p: GeoPoint, _ a: GeoPoint, _ b: GeoPoint) -> (Double, GeoPoint) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return (p.distance(to: a), a) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = max(0, min(1, t))
        let c = GeoPoint(x: a.x + t * dx, y: a.y + t * dy)
        return (p.distance(to: c), c)
    }

    /// Ray-casting point-in-polygon.
    static func pointInPolygon(_ p: GeoPoint, _ ring: [GeoPoint]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}
