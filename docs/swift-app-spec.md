# Anumaan iOS — Native Swift App Specification

**Status:** Draft v1 · **Source of truth for algorithms:** the Python prototype in this repo
(`anumaan/` engine + `app/` server). This document specifies a native iOS rewrite that runs
entirely on the phone.

---

## 1. Product overview

Anumaan is a **zero-GPS, human-vector navigation system**. Position is not read from GPS;
it is **dead-reckoned** (time × estimated speed) along a precomputed route of road-network
**milestones** (intersections, stop signs, lights), and continuously **corrected by the
phone's motion sensors**: stopping at a node snaps you to it, a sensed turn confirms it, and
the phone's compass (fused + calibrated against the route geometry) gives a true heading.

The Python prototype proved the design but needs a laptop plus a network "bridge" to receive
the phone's sensors. **This app moves everything onto the phone**, where the sensors live —
eliminating the bridge entirely and upgrading sensing to Apple's built-in fusion.

### One-line premise
> Download an area's roads + offline map once → pick start/destination → drive → the phone's
> own IMU + compass track you through the route node-by-node, fully offline, no GPS.

---

## 2. Goals / non-goals

### Goals
- Run **fully on-device** (iPhone), no companion laptop, no live data connection while driving.
- Use **CoreMotion + CoreLocation** for sensing (accel/gyro/mag fusion, compass heading).
- **Offline maps**: Protomaps **PMTiles** vector basemap rendered with MapLibre Native.
- **On-device routing** over a downloaded OSM road graph.
- Preserve the proven business rules: dead reckoning, hard milestone gate, stop/turn
  confirmation, speed smoothing, heading calibration, wrong-way detection.
- Work with the **free Apple developer tier** (weekly re-sign acceptable during development).

### Non-goals (v1)
- No GPS-based positioning (the whole point is zero-GPS). GPS *may* later be used only for a
  one-time start fix or optional drift correction — explicitly out of scope for v1.
- No App Store distribution, no accounts, no cloud sync.
- No Android (design stays portable, but this spec is iOS/Swift).
- No turn-by-turn voice in v1 (text/visual banner only; voice is a fast-follow).

---

## 3. What changes vs. the Python prototype

| Concern | Python prototype | iOS native |
|---|---|---|
| Sensor source | Phone streams JSON over UDP/HTTP to a laptop bridge | **CoreMotion/CoreLocation on-device** — no network |
| Sensor fusion | Hand-rolled (variance SDE, tilt-compensated compass, complementary filter) | **Apple's fused outputs** (`CMDeviceMotion`: attitude, gravity, userAcceleration, rotationRate, heading; `CLHeading`) + our thin logic on top |
| Heading | DIY compass from accel+mag | `CMDeviceMotion.heading` / `CLHeading.trueHeading` (already fused, calibrated) — we still apply the **vehicle mounting-offset calibration** |
| Map render | MapLibre **GL JS** (browser) | **MapLibre Native iOS** SDK |
| Basemap | `pmtiles extract` (Go CLI) on laptop | Read PMTiles via **HTTP range** from the cloud build, or download a regional file; store locally |
| Road graph | `osmnx` + `networkx` (Python) | **Overpass query** + Swift graph build + **A\*** routing |
| Server/API | FastAPI | none — direct in-process calls |
| Nav engine | `anumaan/state_machine.py` etc. | **straight Swift port** (simple math/state) |

**Net effect:** the biggest pain (the bridge + reachability + screen-sleep dropouts) is gone,
and the hardest sensing work is largely handled by iOS. The new work is the **map-data
pipeline** (Overpass + routing + PMTiles) that previously lived in Python/Go libraries.

---

## 4. Tech stack & dependencies

- **Language/UI:** Swift 5.9+, **SwiftUI** (with UIKit interop where MapLibre needs it).
- **Min target:** iOS 16+.
- **Sensors:** `CoreMotion` (`CMMotionManager`, `CMDeviceMotion`), `CoreLocation`
  (`CLLocationManager` for heading + optional one-shot start fix).
- **Map:** **MapLibre Native iOS** (`MapLibre` Swift package) rendering vector tiles.
- **Offline tiles:** **PMTiles** — either the `protomaps/PMTiles` Swift/ObjC reader, or a
  small Swift implementation of the PMTiles v3 spec (header + directory + range reads).
- **Map data:** Overpass API (HTTP) for the drivable road network; JSON parsing via `Codable`.
- **Routing:** in-house **A\*** / Dijkstra over the parsed graph (no third-party router in v1;
  Valhalla/GraphHopper considered and rejected as too heavy for v1).
- **Persistence:** `FileManager` (GeoJSON/JSON/`.pmtiles` files) + lightweight metadata
  (`Codable` JSON or SwiftData/CoreData if it grows).
- **No backend.** Everything runs on the device.

---

## 5. High-level architecture

```
┌──────────────────────────── iOS app (on the phone) ─────────────────────────────┐
│                                                                                  │
│  CoreMotion / CoreLocation                                                       │
│        │  deviceMotion (50 Hz): gravity, userAccel, rotationRate, attitude,      │
│        │  heading                                                                │
│        ▼                                                                          │
│   SensingService ──────────► MotionState (moving?, headingDeg, yawRate, …)       │
│        │                                                                          │
│        ▼                                                                          │
│   NavigationEngine  ◄──── Route (milestones + leg bearings + expected turns)     │
│   (dead reckoning, hard gate, stop/turn confirm, speed smoothing, calibration)   │
│        │  publishes NavState (position, current node, ETA, true heading, …)      │
│        ▼                                                                          │
│   SwiftUI views  ──────────► MapLibre Native (PMTiles basemap + route + vehicle) │
│                                                                                  │
│  MapDataService:  Overpass → road graph,   PMTiles (range/region) → basemap      │
│  RoutingService:  A* over graph → milestone array + bearings + turns             │
│  Store:           areas, home, last route on disk                                │
└──────────────────────────────────────────────────────────────────────────────────┘
```

Single process, observable state (`@Observable` / `ObservableObject`), a fixed-rate engine
tick driven by the CoreMotion update callback (or a `CADisplayLink`/timer).

---

## 6. Sensing (CoreMotion / CoreLocation)

Subscribe to `CMMotionManager.startDeviceMotionUpdates(using:.xMagneticNorthZVertical)` at
~50 Hz. Each `CMDeviceMotion` sample gives:

- `gravity` (unit g, gravity direction) — for tilt reference.
- `userAcceleration` (g, **gravity removed**) — cleaner "is the vehicle vibrating/moving".
- `rotationRate` (rad/s) — yaw/pitch/roll rates.
- `attitude` (roll/pitch/yaw quaternion) — fused orientation.
- `heading` (degrees, when using a magnetic-north reference frame) — **device heading**.

Also start `CLLocationManager.startUpdatingHeading()` for `CLHeading.trueHeading` +
`headingAccuracy` (an alternative / cross-check heading source; iOS handles compass
calibration and the "figure-8" UI prompt).

### Derived signals (`MotionState`)
| Signal | How (iOS) | Replaces prototype's |
|---|---|---|
| `isStationary` (Bool) | Variance of `userAcceleration` magnitude over a 1.5 s window with the **same hysteresis** (below); fused with rotation energy | `SensorFusion` moving/stopped |
| `accelVariance` | population variance of `‖userAcceleration‖` | `accel_variance` |
| `headingDeg` (0–360) | `CMDeviceMotion.heading` (or `CLHeading.trueHeading`) — already drift-free | fused compass `heading_deg` |
| `headingChangeDeg` (per leg) | signed Δheading since leg start (shortest-angle) | gyro yaw integration |
| `yawRateDps` | `rotationRate.z` projected onto gravity → deg/s, lightly smoothed | `yaw_rate_dps` |

> **Why this is simpler than the prototype:** iOS already fuses accel+gyro+mag into a stable,
> drift-free heading and gravity-separated acceleration. We keep only the **decision logic**
> (hysteresis thresholds, per-leg heading change), not the raw fusion math. Keep
> `anumaan/fusion.py` as the reference if iOS heading proves noisy in a metal car cabin and we
> need to fall back to raw accel+gyro+mag.

### Hysteresis (port verbatim from `anumaan/sde.py`)
- `STATIONARY_THRESHOLD` and `MOVING_THRESHOLD` are a Schmitt trigger (gap prevents chatter).
- To go **moving**: variance > moving-threshold for `MOVING_HOLD` **or** sustained rotation.
- To go **stationary**: variance < stationary-threshold for `STATIONARY_HOLD` **and** not rotating.
- Note: prototype thresholds were tuned for raw accel (~1 g / ~9.8 m/s²). With
  `userAcceleration` (gravity removed, ~0 at rest), **re-tune thresholds on-device** — the
  *shape* of the logic is identical, the numbers will differ. Treat all constants as tunables.

---

## 7. Data models (Swift)

Port of `anumaan/models.py` + the route structures from `app/routing.py`.

```swift
struct Milestone: Codable, Identifiable {
    let id: String          // OSM node id
    let type: String        // "stop_sign" | "traffic_light" | "intersection" | "destination"
    let name: String        // street / landmark
    let distanceFromPrior: Double   // meters
    let targetSpeedLimit: Double    // m/s
}

struct RouteNode: Codable {           // one per milestone, with geometry + guidance
    let id: String
    let lat, lon: Double
    let cumulativeM: Double           // meters from start
    let turnAngle: Double             // signed expected turn at this node (deg, + = right)
    let turnLabel: String             // "left" | "right" | "straight" | "sharp left" | …
    let legBearing: Double            // compass bearing of the leg INTO this node
    let legStraight: Bool             // low-sinuosity leg ⇒ usable for calibration
}

struct Route: Codable {
    let slug: String
    let coords: [[Double]]            // dense polyline [[lat,lon], …] for drawing
    let milestones: [Milestone]
    let nodes: [RouteNode]
    let totalDistanceM: Double
    let estTimeS: Double
}

struct NavState {                     // mutable, observable
    var currentMilestoneIndex: Int    // node we're heading toward
    var estimatedSpeed: Double        // m/s
    var timeEnteredLeg: TimeInterval
    var accumulatedDistance: Double   // meters on current leg (capped at leg length)
    var velocityHistory: [Double]
}

struct MotionState {                  // from SensingService
    var isStationary: Bool
    var accelVariance: Double
    var headingDeg: Double
    var headingChangeDeg: Double      // since leg start
    var yawRateDps: Double
    var hasMotion: Bool               // CoreMotion available & delivering
}

struct Area: Codable, Identifiable {  // a downloaded region
    var id: String { slug }
    let slug, name: String
    let lat, lon, radiusM: Double
    let bbox: [Double]                // [north, south, east, west]
    let nodeCount, edgeCount: Int
    let hasBasemap: Bool
    let createdAt: Date
}
```

---

## 8. Navigation engine & business rules

Port of `anumaan/state_machine.py`. The engine is a deterministic state machine driven by an
explicit `now` each tick. Keep every constant a tunable.

### Rule 1 — Dead reckoning (with hard gate)
- `T_exp = distanceFromPrior / estimatedSpeed`.
- Each tick: **if moving**, `accumulatedDistance += estimatedSpeed * dt`.
- **Hard gate:** `accumulatedDistance = min(accumulatedDistance, distanceFromPrior)` — the
  vehicle marker rolls up to the next node and **holds there**; it never glides past until
  arrival is confirmed.

### Motion gate (telemetry → movement)
- Advance only when the sensor says **moving** (fresh CoreMotion, not stationary).
- "Stale" doesn't apply on-device the way it did with the network bridge, but keep a guard:
  if CoreMotion stops delivering, treat as stopped (`hasMotion == false` ⇒ hold).

### Rule 2 — Auto-snap (arrival by stopping)
Confirm arrival at the next node when **all**:
- `isStationary` (genuine), **and**
- within `SNAP_RANGE_M` (50 m) of the node (`distanceFromPrior - accumulatedDistance ≤ 50`), **and**
- leg has lasted ≥ `MIN_LEG_SECONDS` (3 s) — prevents instant snap on short legs.

### Rule 3 — Turn confirm (arrival by turning)
At a node that expects a significant turn:
- `|expectedTurn| ≥ TURN_SIGNIFICANT_DEG` (30°), within `TURN_RANGE_M` (120 m) of the node,
  and sensed `|headingChange| ≥ TURN_CONFIRM_FRAC` (0.5) × `|expectedTurn|` ⇒ **confirm**.
- v1 matches on **magnitude** (robust). **v2 (enabled by calibration):** also require the
  post-turn **trueHeading ≈ next leg's bearing** → confirms the *correct* turn and flags a
  *wrong* one (see §9).

### Rule 4 — Speed smoothing
On any confirmed arrival:
- `V_true = distanceFromPrior / max(t_actual, MIN_LEG_SECONDS)` (clamp avoids divide-by-tiny).
- `estimatedSpeed = clamp(0.7·estimatedSpeed + 0.3·V_true, SPEED_MIN, SPEED_MAX)` =
  `[1.0, 45.0]` m/s.

### Manual override
- "✓ I've reached: <next node>" button → confirm the current node immediately (same handler),
  snapping the marker forward and recalibrating speed.

### Constants (initial values; all tunable)
```
SNAP_RANGE_M = 50            MIN_LEG_SECONDS = 3.0
SPEED_MIN = 1.0  SPEED_MAX = 45.0   (m/s)
SMOOTH_RETAIN = 0.7  SMOOTH_OBSERVE = 0.3
TURN_SIGNIFICANT_DEG = 30  TURN_CONFIRM_FRAC = 0.5  TURN_RANGE_M = 120
SDE: STATIONARY_THRESHOLD, MOVING_THRESHOLD (re-tune for userAcceleration),
     STATIONARY_HOLD = 1.0s  MOVING_HOLD = 0.8s  ROTATION_MOVING_DPS = 8
CALIB: STRAIGHT_SINUOSITY = 1.08  STRAIGHT_MIN_M = 40  CALIB_YAW_MAX_DPS = 5
       CALIB_OUTLIER_DEG = 40  OFF_ROUTE_DEG = 60  CALIB_MIN_SAMPLES ≈ 40
```

---

## 9. Heading calibration & wrong-way detection

Port of `HeadingCalibration` (`anumaan/fusion.py`) + the nav-loop wiring in `app/nav_session.py`.

**Problem:** the phone's heading is the *device* heading; the vehicle's heading differs by a
constant mounting offset.
**Insight (no user prompt):** on a **known-straight leg** (`legStraight == true`), while
**moving** and **not turning** (`|yawRate| < CALIB_YAW_MAX_DPS`), the vehicle's true bearing
equals the leg's `legBearing`. So sample `offset = headingDeg − legBearing` into a **circular
EMA** (sin/cos accumulators; wrap-safe across north). Once converged (`≥ CALIB_MIN_SAMPLES`):

- `trueHeading = headingDeg − offset` everywhere.
- **Outlier rejection:** once calibrated, ignore samples whose implied offset is >
  `CALIB_OUTLIER_DEG` from the established one (a wrong turn must not corrupt the offset).
- **Wrong-way / off-route:** while moving and not turning, if
  `|angleDiff(trueHeading, currentLegBearing)| > OFF_ROUTE_DEG` (60°) → raise an off-route
  warning.

**v2 upgrade:** use `trueHeading` to make **turn-confirm direction-aware** — only auto-confirm
a turn when the post-turn `trueHeading` matches the next leg's bearing; otherwise flag a wrong
turn instead of confirming it. (The Python prototype found that magnitude-only confirm will
happily confirm a *wrong* turn; calibration is what fixes this.)

> Real-world caveat to validate: car cabins are magnetically noisy (hard/soft-iron). If a
> single offset proves direction-dependent, extend to a **per-heading** offset table or rely
> more on `CLHeading.headingAccuracy` gating. CoreMotion's heading may already be good enough
> that this is a non-issue — measure first.

---

## 10. Map-data pipeline (the new, harder part)

Two artifacts per **Area**, both fetched once (online) then used offline.

### 10a. Road graph (for routing) — via Overpass
- Input: center `(lat, lon)` + `radiusM` (geocode a place string with Apple's `CLGeocoder`,
  or take a map tap).
- Query Overpass for the **drivable** network in the bbox, e.g.:
  ```
  [out:json][timeout:60];
  way["highway"~"motorway|trunk|primary|secondary|tertiary|residential|unclassified|living_street|service"]
     (south,west,north,east);
  (._;>;);  out body;
  ```
- Parse nodes + ways → build an adjacency graph: nodes = OSM node ids with lat/lon; edges =
  consecutive node pairs along each way, with `length` (haversine) and attributes
  (`maxspeed`, `highway`, `name`). Respect `oneway`.
- Persist as a compact JSON/binary graph file under the area folder.
- This replaces `osmnx.graph_from_point` + `ox.save_graphml`.

### 10b. Offline basemap (for display) — PMTiles
- The Protomaps daily cloud build lives at `https://build.protomaps.com/YYYYMMDD.pmtiles`
  (resolve the latest by probing back a few days — see `latest_build_url` in `app/maps.py`).
- Option A (preferred): **download a bbox extract** to a local `basemap.pmtiles`. The Go
  `pmtiles extract` isn't available on iOS, so implement the equivalent: read the PMTiles v3
  header + directories via HTTP **range requests** and copy only the tiles covering the bbox
  into a local PMTiles file. (PMTiles is explicitly designed for partial range reads.)
- Option B (simplest first cut): point MapLibre Native at the **remote** cloud PMTiles via a
  range-reading source for the session, and cache fetched tiles — less "truly offline" until
  cached, but quick to stand up.
- Render with **MapLibre Native** using the **Protomaps basemap style** + the vendored
  **glyphs** (fonts) and **sprite** for offline labels (same assets as `app/static/vendor/`).

### 10c. Storage layout (on device, app sandbox `Documents/`)
```
areas/<slug>/
    graph.json            # parsed road graph
    basemap.pmtiles       # offline vector basemap (Option A)
    meta.json             # Area metadata
home.json                 # saved home location
routes/last.json          # last computed route (optional)
```

---

## 11. Routing (on-device)

Port of `app/routing.py`.

- **Snap** start/destination taps to the nearest graph node (haversine scan; graphs are
  area-sized so linear scan is fine, or use a simple grid index).
- **Shortest path:** **A\*** (haversine heuristic) or Dijkstra over edge `length`. Respect
  one-ways.
- **Milestone conversion:** walk the node path → `Milestone[]` with `distanceFromPrior`
  (edge length) and `targetSpeedLimit` (parse `maxspeed`, fallback by `highway` class).
- **Geometry:** follow real edge geometry (way node coords) for the drawn polyline.
- **Per-node guidance:**
  - `turnAngle` = signed turn at node *i* from bearings of (i-1→i) and (i→i+1); `turnLabel`
    via the same thresholds as `anumaan/turn.py` (`classify_turn`, `TURN_SIGNIFICANT_DEG`).
  - `legBearing` = compass bearing of the leg into node *i*; `legStraight` =
    `straightLineDist ≥ STRAIGHT_MIN_M && edgeLength ≤ STRAIGHT_SINUOSITY × straightLineDist`.

Reference helpers to port: `bearing`, `turn_angle`, `classify_turn` (`anumaan/turn.py`).

---

## 12. UI / screens (SwiftUI + MapLibre Native)

Three sections (mirrors the web app), a persistent full-screen map underneath.

### Maps
- Text field (place) + radius slider → **Download area** (Overpass graph + PMTiles basemap),
  with a progress indicator. List of downloaded areas (select / delete). Selecting an area
  loads its basemap and fits its bbox.

### Home
- Tap the map to drop a home pin → **Save home** (persisted). "Use home" as a start later.

### Navigate
- **Set start** (tap or "Use home") and **Set destination** (tap) → **Compute route** (draws
  the polyline + milestone dots, shows distance/ETA/leg count).
- **Start navigation** →
  - **Camera follows** the vehicle at street zoom (~16); pan pauses follow briefly.
  - Show **only the next 2 milestones** (current target + the one after).
  - **Vehicle marker** updated each tick by interpolating `accumulatedDistance` along the route
    polyline.
  - **HUD:** speed, progress (km), node N/M, stationary, **heading** (calibrated `trueHeading`
    when available), **sensors** indicator, "moving/stopped" telemetry status.
  - **Turn banner:** "↰ left ~90° at <street>" + sensed angle; amber "did you turn?" when
    held at a turn node with no turn sensed; **red wrong-way warning** when off-route.
  - **"✓ I've reached <next>"** manual-advance button.
  - **Stop** → restore the full route view.

Because sensing is local, the whole live loop is just CoreMotion callbacks driving the engine
and SwiftUI re-rendering — **no polling, no network**.

### Map layer details
- Basemap: MapLibre Native vector source from `basemap.pmtiles` (local file URL) + Protomaps
  style + local glyphs/sprite.
- Overlays: route line (GeoJSON source/layer), milestone circles (+ labels), vehicle as a
  symbol/annotation. Same visual language as the web app.

---

## 13. Permissions & background execution

- **Motion & Fitness** (`NSMotionUsageDescription`) — required for CoreMotion.
- **Location When In Use** (`NSLocationWhenInUseUsageDescription`) — for `CLHeading` (compass)
  and an optional one-time start fix. (We are *not* doing turn-by-turn GPS; heading only.)
- **Background modes:** to keep navigating with the screen off / app backgrounded while
  driving, enable **Location updates** background mode (heading/location keeps the app alive)
  and/or rely on CoreMotion background delivery. Validate battery impact. Keep the screen-on
  "always" option (`UIApplication.isIdleTimerDisabled`) as the simple path for v1.
- **Free-tier note:** background modes generally work with free provisioning; the 7-day
  re-sign still applies. No special entitlement purchase needed for v1.

---

## 14. Project structure (Xcode)

```
Anumaan/
  App/                 AnumaanApp.swift, AppState (@Observable)
  Models/              Milestone, Route, RouteNode, NavState, MotionState, Area
  Engine/
    NavigationEngine.swift     # rules 1–4, hard gate, manual advance
    MotionDecider.swift        # hysteresis stop/go from userAcceleration + rotation
    HeadingCalibration.swift   # circular-EMA offset, true heading, off-route
    Turn.swift                 # bearing, turnAngle, classifyTurn
  Sensing/
    SensingService.swift       # CMMotionManager + CLLocationManager → MotionState
  MapData/
    MapDataService.swift       # Overpass download, area storage
    OverpassClient.swift
    GraphBuilder.swift
    PMTilesReader.swift        # v3 header/dir + range reads (or wrap a lib)
    AreaStore.swift            # FileManager persistence
  Routing/
    RoutingService.swift       # nearest node, A*, milestone conversion, guidance
  Map/
    MapView.swift              # MapLibre Native wrapper (UIViewRepresentable)
    RouteOverlay.swift, VehicleAnnotation.swift
  UI/
    MapsView.swift, HomeView.swift, NavigateView.swift, HUDView.swift, TurnBanner.swift
  Resources/
    protomaps-style.json, glyphs/, sprites/   # vendored offline map assets
  Info.plist            # usage strings + background modes
```

---

## 15. Phased implementation plan

1. **Sensing spike.** SwiftUI app that prints `MotionState` from CoreMotion (stop/go,
   heading, yaw). Re-tune the hysteresis thresholds for `userAcceleration`. *De-risks the
   sensors before anything else.*
2. **Map render.** MapLibre Native showing a PMTiles basemap (Option B remote first, then
   Option A local extract) with the Protomaps style + offline glyphs/sprite.
3. **Area download.** Overpass → graph → persisted Area; basemap extract; Maps screen.
4. **Routing.** A* + milestone conversion + bearings/turns; draw the route; Navigate screen.
5. **Engine.** Port rules 1–4 + hard gate + manual advance; vehicle marker follows; HUD.
6. **Turns + calibration.** Heading-change confirm, leg-bearing offset calibration, off-route
   + (v2) direction-aware turn confirm.
7. **Polish.** Background mode, battery, error states, empty states, settings for tunables.

Each phase is independently demoable on-device.

---

## 16. Risks & open questions

- **Magnetic distortion in cars** — does CoreMotion's heading stay usable in a metal cabin?
  Measure early; the leg-bearing calibration is the mitigation, possibly per-heading.
- **PMTiles on iOS** — is a maintained Swift reader available, or do we implement v3 range
  reads ourselves? (Spec assumes we may implement it; it's well-documented and small.)
- **On-device routing scale** — A* over a city-radius graph is fine; very large areas may need
  an index. Keep radii modest (matches the prototype).
- **`userAcceleration` thresholds** — gravity-removed accel changes the variance scale; all SDE
  constants must be re-tuned on real drives.
- **Background execution & battery** — sustained 50 Hz motion + map render while backgrounded.
  Validate; offer a "keep screen on" simple mode.
- **The fundamental ceiling is unchanged:** zero-GPS dead reckoning is an *estimate* between
  nodes, corrected at nodes. Moving slowly still advances at the estimated speed. This app
  doesn't fix that (by design); it just senses the corrections better.

---

## 17. Prototype → Swift reference map

| Swift target | Port from (Python) |
|---|---|
| `NavigationEngine` | `anumaan/state_machine.py` (rules, gate, snap, smoothing, manual advance) |
| `MotionDecider` | `anumaan/sde.py` (hysteresis) + `anumaan/fusion.py` (moving/stopped, rotation) |
| `HeadingCalibration` | `anumaan/fusion.py` `HeadingCalibration` + calib wiring in `app/nav_session.py` |
| `Turn` | `anumaan/turn.py` (`bearing`, `turn_angle`, `classify_turn`, constants) |
| `RoutingService` | `app/routing.py` (nearest node, shortest path, milestone + bearings + turns) |
| `MapDataService` | `app/maps.py` (download, area model, build-url probing) — minus `osmnx`/`pmtiles` CLI |
| `NavState` snapshot | `NavSession.state()` in `app/nav_session.py` (fields the HUD reads) |
| UI screens | `app/static/index.html` + `app.js` (Maps/Home/Navigate, HUD, turn banner) |

> Keep the Python prototype runnable as the **reference implementation and test oracle**: its
> 33 tests encode the exact rule behavior (gate, snap, smoothing, turn geometry, fusion drift,
> calibration offset recovery). Mirror them as Swift unit tests.

---

## 18. Appendix — sensor notes

- Start device motion with a magnetic-north-referenced frame so `heading` is populated:
  `motionManager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: queue) { … }`.
- Prefer `CMDeviceMotion.userAcceleration` (gravity removed) for the moving/stopped variance;
  fall back to raw accel + our fusion only if needed.
- `rotationRate.z` is yaw in the device frame; for a mounted phone the vertical component is
  what matters — project onto `gravity` like `anumaan/fusion.py` does, or trust `attitude.yaw`
  deltas.
- Cross-check `CMDeviceMotion.heading` against `CLHeading.trueHeading`/`headingAccuracy`; gate
  calibration on good `headingAccuracy`.
- All thresholds in §8/§9 are **starting points from the prototype** and must be re-tuned on
  real drives with real CoreMotion data.
```
