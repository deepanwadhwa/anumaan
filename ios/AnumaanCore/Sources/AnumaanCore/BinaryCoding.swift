import Foundation

/// Compact little-endian binary encoders for the heavy offline layers (the DEM's
/// hundreds of thousands of Int16 elevations, and the feature geometry). Storing
/// these as JSON text was multi-MB and slow to decode on the main thread; raw
/// binary is ~2 bytes/sample and parses with simple byte reads.

struct BinWriter {
    private(set) var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func i32(_ v: Int) { putU32(UInt32(bitPattern: Int32(v))) }
    mutating func f64(_ v: Double) { putU64(v.bitPattern) }
    mutating func f32(_ v: Double) { putU32(Float(v).bitPattern) }
    mutating func str(_ s: String) { let b = Array(s.utf8); i32(b.count); data.append(contentsOf: b) }
    mutating func i16s(_ a: [Int16]) { a.withUnsafeBytes { data.append(contentsOf: $0) } }   // LE on iOS
    private mutating func putU32(_ v: UInt32) {
        for i in 0..<4 { data.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) }
    }
    private mutating func putU64(_ v: UInt64) {
        for i in 0..<8 { data.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) }
    }
}

struct BinReader {
    private let b: [UInt8]; private var o = 0
    init(_ d: Data) { b = [UInt8](d) }
    private var left: Int { b.count - o }

    mutating func u8() -> UInt8? { guard left >= 1 else { return nil }; defer { o += 1 }; return b[o] }
    mutating func u32() -> UInt32? {
        guard left >= 4 else { return nil }
        let v = UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
        o += 4; return v
    }
    mutating func i32() -> Int? { u32().map { Int(Int32(bitPattern: $0)) } }
    mutating func u64() -> UInt64? {
        guard left >= 8 else { return nil }
        var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(b[o + i]) << (8 * UInt64(i)) }
        o += 8; return v
    }
    mutating func f64() -> Double? { u64().map { Double(bitPattern: $0) } }
    mutating func f32() -> Double? { u32().map { Double(Float(bitPattern: $0)) } }
    mutating func str() -> String? {
        guard let n = i32(), n >= 0, left >= n else { return nil }
        let s = String(decoding: b[o..<o + n], as: UTF8.self); o += n; return s
    }
    mutating func i16s(_ count: Int) -> [Int16]? {
        guard count >= 0, left >= count * 2 else { return nil }
        var out = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = Int16(bitPattern: UInt16(b[o + 2 * i]) | (UInt16(b[o + 2 * i + 1]) << 8))
        }
        o += count * 2; return out
    }
}

public extension TerrariumDEM {
    func encodedBinary() -> Data {
        var w = BinWriter()
        w.u8(1)                                              // version
        w.i32(z); w.i32(px0); w.i32(py0); w.i32(width); w.i32(height)
        w.f64(originLat); w.f64(originLon)
        w.i16s(elev)
        return w.data
    }
    static func decodeBinary(_ data: Data) -> TerrariumDEM? {
        var r = BinReader(data)
        guard r.u8() == 1, let z = r.i32(), let px0 = r.i32(), let py0 = r.i32(),
              let width = r.i32(), let height = r.i32(),
              let oLat = r.f64(), let oLon = r.f64(),
              let elev = r.i16s(width * height) else { return nil }
        return TerrariumDEM(z: z, px0: px0, py0: py0, width: width, height: height,
                            elev: elev, originLat: oLat, originLon: oLon)
    }
}

public extension FeatureField {
    func encodedBinary() -> Data {
        var w = BinWriter()
        w.u8(1)
        w.f64(originLat); w.f64(originLon)
        w.i32(features.count)
        for f in features {
            w.str(f.kind.rawValue)
            w.u8(f.isArea ? 1 : 0)
            w.u8(f.name != nil ? 1 : 0); if let n = f.name { w.str(n) }
            w.i32(f.points.count)
            for p in f.points { w.f32(p.x); w.f32(p.y) }    // Float32 — sub-meter at survival range
        }
        return w.data
    }
    static func decodeBinary(_ data: Data) -> FeatureField? {
        var r = BinReader(data)
        guard r.u8() == 1, let oLat = r.f64(), let oLon = r.f64(), let n = r.i32(), n >= 0 else { return nil }
        var feats: [MapFeature] = []; feats.reserveCapacity(n)
        for _ in 0..<n {
            guard let raw = r.str(), let kind = MapFeature.Kind(rawValue: raw),
                  let area = r.u8(), let hasName = r.u8() else { return nil }
            var name: String?
            if hasName == 1 { guard let nm = r.str() else { return nil }; name = nm }
            guard let pc = r.i32(), pc >= 0 else { return nil }
            var pts: [GeoPoint] = []; pts.reserveCapacity(pc)
            for _ in 0..<pc { guard let x = r.f32(), let y = r.f32() else { return nil }; pts.append(GeoPoint(x: x, y: y)) }
            feats.append(MapFeature(kind: kind, isArea: area == 1, points: pts, name: name))
        }
        return FeatureField(originLat: oLat, originLon: oLon, features: feats)
    }
}
