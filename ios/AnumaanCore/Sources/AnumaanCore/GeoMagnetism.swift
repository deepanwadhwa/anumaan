import Foundation

/// World Magnetic Model (WMM2025) declination — the angle between magnetic north
/// (what the compass reads) and true north (what the DEM uses). Computed fully
/// offline from the area's known lat/lon, then applied as a constant heading
/// offset so the recovery engine samples the terrain along the *true* bearing.
///
/// Coefficients: NOAA NCEI WMM2025.COF (epoch 2025.0, valid 2025–2030).
/// Validated against NOAA's official WMM2025 test values (see self-tests).
public enum GeoMagnetism {
    private static let nMax = 12
    private static let a = 6371.2          // km, geomagnetic reference radius
    private static let epoch = 2025.0

    /// Magnetic declination (degrees, +east) at a geodetic location.
    public static func declination(latDeg: Double, lonDeg: Double, year: Double,
                                   altKm: Double = 0) -> Double {
        let nt = (nMax + 1) * (nMax + 2) / 2
        var g = [Double](repeating: 0, count: nt), h = [Double](repeating: 0, count: nt)
        for i in 0..<nt { g[i] = g0[i] + (year - epoch) * gd[i]; h[i] = h0[i] + (year - epoch) * hd[i] }

        // Geodetic → geocentric (WGS84).
        let f = 1 / 298.257223563, awgs = 6378.137, e2 = f * (2 - f)
        let latR = latDeg * .pi / 180, lonR = lonDeg * .pi / 180
        let sLat = sin(latR), cLat = cos(latR)
        let rc = awgs / (1 - e2 * sLat * sLat).squareRoot()
        let xp = (rc + altKm) * cLat
        let zp = (rc * (1 - e2) + altKm) * sLat
        let r = (xp * xp + zp * zp).squareRoot()
        let gcLat = asin(zp / r)               // geocentric latitude (rad)

        var P = [Double](repeating: 0, count: nt), dP = [Double](repeating: 0, count: nt)
        legendre(&P, &dP, x: sin(gcLat))

        let ar = a / r
        var rrPow = [Double](repeating: 0, count: nMax + 1)
        var arpow = ar * ar
        for n in 1...nMax { arpow *= ar; rrPow[n] = arpow }   // (a/r)^(n+2)

        var Bx = 0.0, By = 0.0, Bz = 0.0
        for n in 1...nMax {
            for m in 0...n {
                let idx = n * (n + 1) / 2 + m
                let mr = Double(m) * lonR
                let gcs = g[idx] * cos(mr) + h[idx] * sin(mr)
                let gss = g[idx] * sin(mr) - h[idx] * cos(mr)
                Bz -= rrPow[n] * gcs * Double(n + 1) * P[idx]
                By += rrPow[n] * gss * Double(m) * P[idx]
                Bx -= rrPow[n] * gcs * dP[idx]
            }
        }
        let cgc = cos(gcLat)
        if abs(cgc) > 1e-10 { By /= cgc }
        // Rotate geocentric → geodetic (only Bx changes; By is invariant).
        let psi = gcLat - latR
        let Bxg = Bx * cos(psi) - Bz * sin(psi)
        return atan2(By, Bxg) * 180 / .pi
    }

    /// Schmidt semi-normalized associated Legendre functions + d/dlat, indexed by
    /// `n(n+1)/2 + m`. (Port of NOAA's MAG_PcupLow.)
    private static func legendre(_ P: inout [Double], _ dP: inout [Double], x: Double) {
        P[0] = 1; dP[0] = 0
        let z = ((1 - x) * (1 + x)).squareRoot()
        for n in 1...nMax {
            for m in 0...n {
                let index = n * (n + 1) / 2 + m
                if n == m {
                    let i1 = (n - 1) * n / 2 + m - 1
                    P[index] = z * P[i1]
                    dP[index] = z * dP[i1] + x * P[i1]
                } else if n == 1 && m == 0 {
                    P[index] = x * P[0]
                    dP[index] = x * dP[0] - z * P[0]
                } else {
                    let i1 = (n - 2) * (n - 1) / 2 + m
                    let i2 = (n - 1) * n / 2 + m
                    if m > n - 2 {
                        P[index] = x * P[i2]
                        dP[index] = x * dP[i2] - z * P[i2]
                    } else {
                        let k = Double((n - 1) * (n - 1) - m * m) / Double((2 * n - 1) * (2 * n - 3))
                        P[index] = x * P[i2] - k * P[i1]
                        dP[index] = x * dP[i2] - z * P[i2] - k * dP[i1]
                    }
                }
            }
        }
        var s = [Double](repeating: 0, count: P.count); s[0] = 1
        for n in 1...nMax {
            let index = n * (n + 1) / 2, i1 = (n - 1) * n / 2
            s[index] = s[i1] * Double(2 * n - 1) / Double(n)
            for m in 1...n {
                let idx = n * (n + 1) / 2 + m
                s[idx] = s[idx - 1] * (Double((n - m + 1) * (m == 1 ? 2 : 1)) / Double(n + m)).squareRoot()
            }
        }
        for n in 1...nMax {
            for m in 0...n {
                let idx = n * (n + 1) / 2 + m
                P[idx] *= s[idx]
                dP[idx] = -dP[idx] * s[idx]
            }
        }
    }

    // WMM2025 Gauss coefficients g0,h0 (nT) and secular variation gd,hd (nT/yr),
    // flattened by index n(n+1)/2+m. Parsed once from the official table.
    private static let (g0, h0, gd, hd): ([Double], [Double], [Double], [Double]) = {
        let nt = (nMax + 1) * (nMax + 2) / 2
        var g = [Double](repeating: 0, count: nt), h = g, gD = g, hD = g
        for line in coef.split(separator: "\n") {
            let f = line.split(separator: " ").compactMap { Double($0) }
            guard f.count == 6 else { continue }
            let n = Int(f[0]), m = Int(f[1]), idx = n * (n + 1) / 2 + m
            g[idx] = f[2]; h[idx] = f[3]; gD[idx] = f[4]; hD[idx] = f[5]
        }
        return (g, h, gD, hD)
    }()

    private static let coef = """
    1 0 -29351.8 0.0 12.0 0.0
    1 1 -1410.8 4545.4 9.7 -21.5
    2 0 -2556.6 0.0 -11.6 0.0
    2 1 2951.1 -3133.6 -5.2 -27.7
    2 2 1649.3 -815.1 -8.0 -12.1
    3 0 1361.0 0.0 -1.3 0.0
    3 1 -2404.1 -56.6 -4.2 4.0
    3 2 1243.8 237.5 0.4 -0.3
    3 3 453.6 -549.5 -15.6 -4.1
    4 0 895.0 0.0 -1.6 0.0
    4 1 799.5 278.6 -2.4 -1.1
    4 2 55.7 -133.9 -6.0 4.1
    4 3 -281.1 212.0 5.6 1.6
    4 4 12.1 -375.6 -7.0 -4.4
    5 0 -233.2 0.0 0.6 0.0
    5 1 368.9 45.4 1.4 -0.5
    5 2 187.2 220.2 0.0 2.2
    5 3 -138.7 -122.9 0.6 0.4
    5 4 -142.0 43.0 2.2 1.7
    5 5 20.9 106.1 0.9 1.9
    6 0 64.4 0.0 -0.2 0.0
    6 1 63.8 -18.4 -0.4 0.3
    6 2 76.9 16.8 0.9 -1.6
    6 3 -115.7 48.8 1.2 -0.4
    6 4 -40.9 -59.8 -0.9 0.9
    6 5 14.9 10.9 0.3 0.7
    6 6 -60.7 72.7 0.9 0.9
    7 0 79.5 0.0 -0.0 0.0
    7 1 -77.0 -48.9 -0.1 0.6
    7 2 -8.8 -14.4 -0.1 0.5
    7 3 59.3 -1.0 0.5 -0.8
    7 4 15.8 23.4 -0.1 0.0
    7 5 2.5 -7.4 -0.8 -1.0
    7 6 -11.1 -25.1 -0.8 0.6
    7 7 14.2 -2.3 0.8 -0.2
    8 0 23.2 0.0 -0.1 0.0
    8 1 10.8 7.1 0.2 -0.2
    8 2 -17.5 -12.6 0.0 0.5
    8 3 2.0 11.4 0.5 -0.4
    8 4 -21.7 -9.7 -0.1 0.4
    8 5 16.9 12.7 0.3 -0.5
    8 6 15.0 0.7 0.2 -0.6
    8 7 -16.8 -5.2 -0.0 0.3
    8 8 0.9 3.9 0.2 0.2
    9 0 4.6 0.0 -0.0 0.0
    9 1 7.8 -24.8 -0.1 -0.3
    9 2 3.0 12.2 0.1 0.3
    9 3 -0.2 8.3 0.3 -0.3
    9 4 -2.5 -3.3 -0.3 0.3
    9 5 -13.1 -5.2 0.0 0.2
    9 6 2.4 7.2 0.3 -0.1
    9 7 8.6 -0.6 -0.1 -0.2
    9 8 -8.7 0.8 0.1 0.4
    9 9 -12.9 10.0 -0.1 0.1
    10 0 -1.3 0.0 0.1 0.0
    10 1 -6.4 3.3 0.0 0.0
    10 2 0.2 0.0 0.1 -0.0
    10 3 2.0 2.4 0.1 -0.2
    10 4 -1.0 5.3 -0.0 0.1
    10 5 -0.6 -9.1 -0.3 -0.1
    10 6 -0.9 0.4 0.0 0.1
    10 7 1.5 -4.2 -0.1 0.0
    10 8 0.9 -3.8 -0.1 -0.1
    10 9 -2.7 0.9 -0.0 0.2
    10 10 -3.9 -9.1 -0.0 -0.0
    11 0 2.9 0.0 0.0 0.0
    11 1 -1.5 0.0 -0.0 -0.0
    11 2 -2.5 2.9 0.0 0.1
    11 3 2.4 -0.6 0.0 -0.0
    11 4 -0.6 0.2 0.0 0.1
    11 5 -0.1 0.5 -0.1 -0.0
    11 6 -0.6 -0.3 0.0 -0.0
    11 7 -0.1 -1.2 -0.0 0.1
    11 8 1.1 -1.7 -0.1 -0.0
    11 9 -1.0 -2.9 -0.1 0.0
    11 10 -0.2 -1.8 -0.1 0.0
    11 11 2.6 -2.3 -0.1 0.0
    12 0 -2.0 0.0 0.0 0.0
    12 1 -0.2 -1.3 0.0 -0.0
    12 2 0.3 0.7 -0.0 0.0
    12 3 1.2 1.0 -0.0 -0.1
    12 4 -1.3 -1.4 -0.0 0.1
    12 5 0.6 -0.0 -0.0 -0.0
    12 6 0.6 0.6 0.1 -0.0
    12 7 0.5 -0.1 -0.0 -0.0
    12 8 -0.1 0.8 0.0 0.0
    12 9 -0.4 0.1 0.0 -0.0
    12 10 -0.2 -1.0 -0.1 -0.0
    12 11 -1.3 0.1 -0.0 0.0
    12 12 -0.7 0.2 -0.1 -0.1
    """
}
