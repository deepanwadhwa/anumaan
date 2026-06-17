import Foundation

/// Minimal Mapbox Vector Tile (MVT) decoder — pure Swift, no dependency (we
/// hand-roll just enough protobuf to read OpenFreeMap's `.pbf` tiles). Gives us
/// water/waterway/landcover/peak geometry straight from the basemap tiles, so we
/// never have to query Overpass for terrain features.
public enum MVT {
    public struct Value {
        public let string: String?
        public let number: Double?
    }
    public struct Feature {
        public let geomType: Int                 // 1 = point, 2 = line, 3 = polygon
        public let rings: [[(x: Int32, y: Int32)]]   // tile-space (0…extent), one array per part/ring
        public let properties: [String: Value]
    }
    public struct Layer {
        public let name: String
        public let extent: Int
        public let features: [Feature]
    }
    public struct Tile { public let layers: [Layer] }

    public static func decode(_ data: Data) throws -> Tile {
        var layers: [Layer] = []
        var r = Reader([UInt8](data))
        while r.hasMore {
            let (field, wire) = r.tag()
            if field == 3, wire == 2 { layers.append(decodeLayer(r.lengthDelimited())) }
            else { r.skip(wire) }
        }
        return Tile(layers: layers)
    }

    // MARK: layer / feature / value

    private static func decodeLayer(_ bytes: [UInt8]) -> Layer {
        var name = "", extent = 4096
        var keys: [String] = [], values: [Value] = []
        var rawFeatures: [(type: Int, tags: [Int], geom: [UInt32])] = []
        var r = Reader(bytes)
        while r.hasMore {
            let (field, wire) = r.tag()
            switch field {
            case 1: name = String(decoding: r.lengthDelimited(), as: UTF8.self)
            case 2: rawFeatures.append(decodeFeature(r.lengthDelimited()))
            case 3: keys.append(String(decoding: r.lengthDelimited(), as: UTF8.self))
            case 4: values.append(decodeValue(r.lengthDelimited()))
            case 5: extent = Int(r.varint())
            default: r.skip(wire)
            }
        }
        let features = rawFeatures.map { rf -> Feature in
            var props: [String: Value] = [:]
            var i = 0
            while i + 1 < rf.tags.count {
                let k = rf.tags[i], v = rf.tags[i + 1]
                if k < keys.count, v < values.count { props[keys[k]] = values[v] }
                i += 2
            }
            return Feature(geomType: rf.type, rings: decodeGeometry(rf.geom), properties: props)
        }
        return Layer(name: name, extent: extent, features: features)
    }

    private static func decodeFeature(_ bytes: [UInt8]) -> (type: Int, tags: [Int], geom: [UInt32]) {
        var type = 0, tags: [Int] = [], geom: [UInt32] = []
        var r = Reader(bytes)
        while r.hasMore {
            let (field, wire) = r.tag()
            switch field {
            case 1: _ = r.varint()                       // feature id
            case 2: var s = Reader(r.lengthDelimited()); while s.hasMore { tags.append(Int(s.varint())) }
            case 3: type = Int(r.varint())
            case 4: var s = Reader(r.lengthDelimited()); while s.hasMore { geom.append(UInt32(truncatingIfNeeded: s.varint())) }
            default: r.skip(wire)
            }
        }
        return (type, tags, geom)
    }

    private static func decodeValue(_ bytes: [UInt8]) -> Value {
        var s: String?, n: Double?
        var r = Reader(bytes)
        while r.hasMore {
            let (field, wire) = r.tag()
            switch field {
            case 1: s = String(decoding: r.lengthDelimited(), as: UTF8.self)
            case 2: n = Double(Float(bitPattern: r.fixed32()))
            case 3: n = Double(bitPattern: r.fixed64())
            case 4: n = Double(Int64(bitPattern: r.varint()))
            case 5: n = Double(r.varint())
            case 6: let z = r.varint(); n = Double(Int64(bitPattern: z >> 1) ^ -Int64(bitPattern: z & 1))
            case 7: n = r.varint() == 0 ? 0 : 1
            default: r.skip(wire)
            }
        }
        return Value(string: s, number: n)
    }

    /// MVT geometry command stream → absolute tile-space rings.
    public static func decodeGeometry(_ g: [UInt32]) -> [[(x: Int32, y: Int32)]] {
        var rings: [[(Int32, Int32)]] = [], ring: [(Int32, Int32)] = []
        var x: Int32 = 0, y: Int32 = 0, i = 0
        func zig(_ v: UInt32) -> Int32 { Int32(bitPattern: v >> 1) ^ -Int32(bitPattern: v & 1) }
        while i < g.count {
            let cmd = g[i] & 0x7, count = Int(g[i] >> 3); i += 1
            switch cmd {
            case 1:                                       // MoveTo (starts a new part)
                for _ in 0..<count where i + 1 < g.count {
                    x = x &+ zig(g[i]); y = y &+ zig(g[i + 1]); i += 2
                    if !ring.isEmpty { rings.append(ring); ring = [] }
                    ring.append((x, y))
                }
            case 2:                                       // LineTo
                for _ in 0..<count where i + 1 < g.count {
                    x = x &+ zig(g[i]); y = y &+ zig(g[i + 1]); i += 2
                    ring.append((x, y))
                }
            case 7:                                       // ClosePath
                if !ring.isEmpty { rings.append(ring); ring = [] }
            default:
                i = g.count
            }
        }
        if !ring.isEmpty { rings.append(ring) }
        return rings
    }

    // MARK: tiny protobuf reader

    struct Reader {
        let b: [UInt8]; var pos = 0
        init(_ bytes: [UInt8]) { b = bytes }
        var hasMore: Bool { pos < b.count }
        mutating func varint() -> UInt64 {
            var result: UInt64 = 0, shift: UInt64 = 0
            while pos < b.count {
                let byte = b[pos]; pos += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
            }
            return result
        }
        mutating func tag() -> (Int, Int) { let t = varint(); return (Int(t >> 3), Int(t & 0x7)) }
        mutating func lengthDelimited() -> [UInt8] {
            let len = Int(varint()); let start = pos; pos = min(pos + len, b.count)
            return Array(b[start..<pos])
        }
        mutating func fixed32() -> UInt32 {
            var v: UInt32 = 0; for k in 0..<4 where pos < b.count { v |= UInt32(b[pos]) << (8 * k); pos += 1 }
            return v
        }
        mutating func fixed64() -> UInt64 {
            var v: UInt64 = 0; for k in 0..<8 where pos < b.count { v |= UInt64(b[pos]) << (8 * k); pos += 1 }
            return v
        }
        mutating func skip(_ wire: Int) {
            switch wire {
            case 0: _ = varint()
            case 1: pos += 8
            case 2: pos = min(pos + Int(varint()), b.count)
            case 5: pos += 4
            default: break
            }
        }
    }
}
