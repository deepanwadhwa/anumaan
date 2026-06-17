import Foundation

/// A physical node on the route (intersection, stop sign, light, destination).
public struct Milestone: Codable, Identifiable, Equatable {
    public let id: String
    public let type: String
    public let name: String
    public let distanceFromPrior: Double   // meters from the previous milestone
    public let targetSpeedLimit: Double    // m/s

    public init(id: String, type: String, distanceFromPrior: Double,
                name: String = "", targetSpeedLimit: Double = 11.0) {
        self.id = id
        self.type = type
        self.distanceFromPrior = distanceFromPrior
        self.name = name
        self.targetSpeedLimit = targetSpeedLimit
    }
}

/// One route node with geometry + turn/leg guidance (from the routing layer).
public struct RouteNode: Codable, Equatable {
    public let id: String
    public let lat: Double
    public let lon: Double
    public let cumulativeM: Double
    public let turnAngle: Double      // signed expected turn at this node (deg, + = right)
    public let turnLabel: String
    public let legBearing: Double     // compass bearing of the leg INTO this node
    public let legStraight: Bool      // low-sinuosity leg ⇒ usable for calibration

    public init(id: String, lat: Double, lon: Double, cumulativeM: Double,
                turnAngle: Double = 0, turnLabel: String = "",
                legBearing: Double = 0, legStraight: Bool = false) {
        self.id = id; self.lat = lat; self.lon = lon; self.cumulativeM = cumulativeM
        self.turnAngle = turnAngle; self.turnLabel = turnLabel
        self.legBearing = legBearing; self.legStraight = legStraight
    }
}

/// A computed route: drawing geometry + milestones + per-node guidance.
public struct Route: Codable, Equatable {
    public let coords: [[Double]]    // dense polyline [[lat,lon], …]
    public let milestones: [Milestone]
    public let nodes: [RouteNode]
    public let totalDistanceM: Double
    public let estTimeS: Double

    public init(coords: [[Double]], milestones: [Milestone], nodes: [RouteNode],
                totalDistanceM: Double, estTimeS: Double) {
        self.coords = coords; self.milestones = milestones; self.nodes = nodes
        self.totalDistanceM = totalDistanceM; self.estTimeS = estTimeS
    }
}

/// What the sensing layer hands the engine each tick.
public struct MotionState {
    public var isStationary: Bool      // genuine SDE stop (false when no fresh data)
    public var isMoving: Bool          // advance dead reckoning this tick?
    public var headingDeg: Double      // absolute compass heading, 0–360
    public var headingChangeDeg: Double // signed Δheading since the leg began
    public var yawRateDps: Double      // smoothed yaw rate (≈0 ⇒ driving straight)
    public var cadence: Double         // live step cadence (steps/sec, 0 ⇒ not stepping)
    public var hasGyro: Bool
    public var hasMag: Bool

    public init(isStationary: Bool = false, isMoving: Bool = false,
                headingDeg: Double = 0, headingChangeDeg: Double = 0,
                yawRateDps: Double = 0, cadence: Double = 0,
                hasGyro: Bool = false, hasMag: Bool = false) {
        self.isStationary = isStationary; self.isMoving = isMoving
        self.headingDeg = headingDeg; self.headingChangeDeg = headingChangeDeg
        self.yawRateDps = yawRateDps; self.cadence = cadence
        self.hasGyro = hasGyro; self.hasMag = hasMag
    }
}
