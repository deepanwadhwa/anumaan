import Foundation

/// Local terrain shape derived straight from the DEM — the cheapest extra signals
/// for recovery, since they need no new download. A lost person always knows which
/// way is downhill and roughly how steep; and with a timestamp we can tell whether
/// the sun reaches a given spot (deep valleys fall into terrain shadow first).
public extension DEMProvider {

    /// Slope magnitude (degrees from horizontal) and the **downhill** compass
    /// bearing (0 = N, 90 = E) at a point, via central differences. nil off-map.
    func slopeAspect(at p: GeoPoint, stepM: Double = 30) -> (slopeDeg: Double, downhillDeg: Double)? {
        guard let eE = elevation(x: p.x + stepM, y: p.y),
              let eW = elevation(x: p.x - stepM, y: p.y),
              let eN = elevation(x: p.x, y: p.y + stepM),
              let eS = elevation(x: p.x, y: p.y - stepM) else { return nil }
        let dzdx = (eE - eW) / (2 * stepM)            // + ⇒ uphill toward east
        let dzdy = (eN - eS) / (2 * stepM)            // + ⇒ uphill toward north
        let slope = atan((dzdx * dzdx + dzdy * dzdy).squareRoot()) * 180 / .pi
        let downX = -dzdx, downY = -dzdy              // downhill = −gradient
        if (downX * downX + downY * downY).squareRoot() < 1e-9 { return (slope, 0) }
        var az = atan2(downX, downY) * 180 / .pi      // bearing from +y(N) toward +x(E)
        if az < 0 { az += 360 }
        return (slope, az)
    }

    /// Is direct sunlight reaching this spot right now? False at night, or when a
    /// ridge in the sun's direction rises above the sun. (Canopy isn't considered
    /// here — that's a separate veg layer.)
    func sunOnGround(at p: GeoPoint, sun: SolarPosition.Sun, rangeM: Double = 5000, step: Double = 60) -> Bool {
        guard sun.elevationDeg > 0 else { return false }
        let horizon = Horizon.maxElevationAngle(dem: self, from: p, headingDeg: sun.azimuthDeg,
                                                rangeM: rangeM, step: step)
        return sun.elevationDeg > horizon
    }
}

/// Smallest absolute difference between two compass bearings (0…180°).
public func bearingDelta(_ a: Double, _ b: Double) -> Double {
    let d = abs((a - b).truncatingRemainder(dividingBy: 360))
    return d > 180 ? 360 - d : d
}
