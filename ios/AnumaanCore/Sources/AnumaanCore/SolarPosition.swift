import Foundation

/// Where the sun is, computed entirely offline from a timestamp + location.
/// (NOAA solar-position algorithm.) Azimuth uses the app's compass convention:
/// 0° = north, 90° = east. Elevation is degrees above the true horizon (negative
/// at night). We feed this the area center + the current time; over a ~100 km box
/// the sun's bearing is effectively constant, so this localizes only via terrain
/// shadowing (see `DEMProvider.sunOnGround`), not by bearing alone.
public enum SolarPosition {
    public struct Sun {
        public let azimuthDeg: Double; public let elevationDeg: Double
        public init(azimuthDeg: Double, elevationDeg: Double) {
            self.azimuthDeg = azimuthDeg; self.elevationDeg = elevationDeg
        }
    }

    /// `unixTime` = seconds since 1970 (UTC). `lonDeg` positive east.
    public static func at(latDeg: Double, lonDeg: Double, unixTime: Double) -> Sun {
        let jd = unixTime / 86_400 + 2_440_587.5
        let T = (jd - 2_451_545.0) / 36_525.0                 // Julian centuries since J2000
        let rad = Double.pi / 180, deg = 180 / Double.pi

        let L0 = mod360(280.46646 + T * (36_000.76983 + T * 0.0003032))
        let M  = 357.52911 + T * (35_999.05029 - 0.0001537 * T)
        let e  = 0.016708634 - T * (0.000042037 + 0.0000001267 * T)
        let Mr = M * rad
        let C = sin(Mr) * (1.914602 - T * (0.004817 + 0.000014 * T))
              + sin(2 * Mr) * (0.019993 - 0.000101 * T)
              + sin(3 * Mr) * 0.000289
        let trueLong = L0 + C
        let omega = 125.04 - 1_934.136 * T
        let appLong = (trueLong - 0.00569 - 0.00478 * sin(omega * rad)) * rad
        let obliq0 = 23 + (26 + (21.448 - T * (46.815 + T * (0.00059 - T * 0.001813))) / 60) / 60
        let obliq = (obliq0 + 0.00256 * cos(omega * rad)) * rad
        let decl = asin(sin(obliq) * sin(appLong))            // solar declination (rad)

        let varY = tan(obliq / 2) * tan(obliq / 2)
        let L0r = L0 * rad
        let eqTime = 4 * deg * (varY * sin(2 * L0r)
                                - 2 * e * sin(Mr)
                                + 4 * e * varY * sin(Mr) * cos(2 * L0r)
                                - 0.5 * varY * varY * sin(4 * L0r)
                                - 1.25 * e * e * sin(2 * Mr))   // minutes

        let minutesUTC = ((jd + 0.5).truncatingRemainder(dividingBy: 1)) * 1_440
        let tst = mod(minutesUTC + eqTime + 4 * lonDeg, 1_440)  // true solar time (min)
        let ha = (tst / 4 < 0 ? tst / 4 + 180 : tst / 4 - 180) * rad   // hour angle (rad)

        let latR = latDeg * rad
        let cosZ = sin(latR) * sin(decl) + cos(latR) * cos(decl) * cos(ha)
        let zenith = acos(clamp(cosZ, -1, 1))
        let elev = 90 - zenith * deg

        let sinZ = sin(zenith)
        var az: Double
        if sinZ < 1e-9 {
            az = 0
        } else {
            let cosAz = clamp((sin(latR) * cos(zenith) - sin(decl)) / (cos(latR) * sinZ), -1, 1)
            let a = acos(cosAz) * deg
            az = ha > 0 ? mod(a + 180, 360) : mod(540 - a, 360)
        }
        return Sun(azimuthDeg: az, elevationDeg: elev)
    }

    private static func mod360(_ x: Double) -> Double { mod(x, 360) }
    private static func mod(_ x: Double, _ m: Double) -> Double { let r = x.truncatingRemainder(dividingBy: m); return r < 0 ? r + m : r }
    private static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }
}
