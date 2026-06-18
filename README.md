# Anumaan

Anumaan (Hindi: अनुमान) means "to estimate", "to deduce", "to reckon roughly". This is a working prototype exploring how far you can get with navigation without GPS.

## The problem we are trying to solve

GPS-free navigation sounds hard, but the core requirements are actually pretty narrow. To route someone from point A to point B without GPS, you need three things:

1. **An offline map** with routing built in, so you can run A* or any shortest-path algorithm without a network connection.
2. **A starting position** on that map, so you know where to begin.
3. **A speed estimate**, so you can predict when you will reach the next known landmark.

If you have all three, you can dead-reckon your way through a road network with reasonable accuracy: the app knows where you started, how fast you are moving, and which roads you are on, so it can estimate when you will arrive at the next intersection.

The hard one is speed. On a phone with no GPS, there is no direct speed measurement. The clean solution would be an OBD dongle plugged into the car's data port, or a smart car that broadcasts its speed over Bluetooth — but I had neither of those. So I did the next best thing: **assume you are driving at the speed limit**, which the map already knows for every road segment.

That assumption is good enough to get the timing right within a few seconds on a typical city block. And the app does not just trust that assumption blindly. Every time you approach a mapped intersection, the app asks: *"Have you reached this intersection yet?"* Your yes or no corrects the position estimate. If your phone's barometer and motion sensors also detect the terrain change expected at that point — an elevation step, a stop — the app can confirm the snap automatically without asking.

That question-and-answer loop is the core of the road navigation engine. Each answered question narrows the set of places you could be, and after a few intersections the position converges to a tight cluster.

### The wilderness problem

Off-road is harder because the road constraint disappears. In a city you can only be *on the road*, which collapses the candidate set dramatically. In a national park or backcountry you could be anywhere.

The approach for wilderness is **terrain contour matching**: as you walk, the rise and fall of the ground traces out an elevation profile. If you have a cached offline elevation map of the area, you can compare that profile against every possible location on the map and find where it fits best.

This is the same principle behind the guidance system in a Tomahawk cruise missile — TERCOM (Terrain Contour Matching). The missile's altimeter measures the terrain below, and the onboard map records the pre-planned corridor; when the two match, the missile knows exactly where it is. We are doing a simpler version of the same thing with a phone barometer and open elevation data.

**What makes it hard** is that big terrain repeats itself. A 3 km walk at 1,400 m elevation on a south-facing slope in the Smokies might look almost identical to a different 3 km walk at the same elevation on a different south-facing slope 8 km away. The engine either nails it or lands on one of these look-alikes — and there is not much in between. The benchmarks below show that split clearly.

---

## What is in this repo

There are two implementations of the same idea.

- **iOS app (`ios/`)** is a native Swift app with three screens: **Navigate** (follow a route by dead reckoning), **Track** (record a walk), and **Lost** (recover your position from the terrain with TERCOM). We built this so we could actually take a phone outside and test whether the dead-reckoning and terrain-matching ideas work in the real world. See [`ios/README.md`](ios/README.md) to build and run it.
- **Web prototype** is a small web app you run on a computer. Your phone streams its sensor data to it over the local network, and the browser shows you moving along a real route with no GPS.
- **Map Simulator** is served at `/sim`. It lets you draw walk paths on a map, synthesize walk telemetry (noisy barometer and heading), and run the Swift recovery engine (`AnumaanSim` CLI) to visualize the particle filter and Q&A engine converging onto your true position.

The rest of this document covers the **web prototype and simulator**.

## Run the web prototype & simulator

This project uses [uv](https://docs.astral.sh/uv/) and the [`pmtiles`](https://docs.protomaps.com/pmtiles/cli) command line tool. Install both once:

```bash
brew install uv pmtiles
uv sync                       # create the environment and install deps from uv.lock
uv run python run_app.py      # serves on http://127.0.0.1:8080
```

To use a real phone on the same network, bind to your LAN address instead:

```bash
uv run python run_app.py --host 0.0.0.0   # the app prints your LAN URL
```

Open the URL in a browser. There are three screens in the sidebar:

1. **Maps.** Type a place (for example, `Asheville, North Carolina, USA`) and a radius, then click **Download area**. This downloads the road network and also extracts a Protomaps vector basemap for the area (one `.pmtiles` file, roughly 1 to 5 MB). Pick the area from the list to load it.
2. **Home.** Click the map to drop your home pin, then click **Save home**.
3. **Navigate.** Set a **Start** (or click **Use home**) and a **Destination** by clicking the map, click **Compute route**, then click **Start navigation**.


## The Map Simulator (`/sim`)

The simulator lets you run and visualize the Anumaan recovery engine entirely inside the browser:

1. Open http://127.0.0.1:8080/sim in your browser.
2. **Offline Map Area Selection**: The sidebar includes a dropdown of all cached areas (loaded from `data/sim_areas.json`). You can also use the geocoding search input to pan/zoom anywhere in the world and click **Download Current View** to download the OSM roads and AWS DEM elevation tiles for a custom area. The selection is persistent across refreshes via `localStorage`.
3. **Walk Modes**: Supports **Paved Roads** (snapping particle filter) and **Off-Trail** (terrain-contour TERCOM matching with road nodes masked out).
4. **Draw and Run**: Click the map to draw your simulated walk path. Once you have at least 2 waypoints, click **Run Sim**.
5. **Q&A Localization Engine**: The simulator calls the Swift `AnumaanSim` CLI, runs the particle filter recovery, and returns the list of hypotheses and questions. You can answer the interactive Q&A questions (Yes/No) in the sidebar to see the hypothesis cloud (orange dots) filter down and converge onto the true location (pink `?` marker).

### Region benchmark

The simulator includes a **Region Benchmarker** that runs hundreds of synthetic walks across a downloaded area and scores how often the engine recovers the correct position. Green paths on the map are walks that were successfully located; red paths are misses. The sidebar shows the aggregate accuracy, median error, and per-walk statistics.

#### Road benchmarks

The road engine performs well on dense road networks. These four runs used a "strict trail" walk style — paths that never reuse a street segment — with a minimum walk distance of 3 km and randomized Q&A (1–4 questions per walk).

| Area | Accuracy | Notes |
|---|---|---|
| Clemson, SC | **90%** | Mixed suburban/rural grid |
| Buffalo, NY | **89%** | Dense urban grid |
| Bangalore, India | **81%** | Complex junction-heavy layout |
| Kyiv, Ukraine | **91%** | Wide arterials, river peninsula |

The numbers are not 100% because some walks are ambiguous even with full map knowledge — two streets of the same length and orientation are genuinely hard to tell apart from motion sensors alone.

![Clemson road benchmark — 90% accuracy](docs/Clemson.png)
*Clemson, SC — 90% of 197 strict-trail walks located to within 13 m median error.*

![Buffalo road benchmark — 89% accuracy](docs/Buffalo.png)
*Buffalo, NY — 89% accuracy on a dense urban grid. Red dots show the small cluster of missed walks near the southern boundary.*

![Bangalore road benchmark — 81% accuracy](docs/Bangalore.png)
*Bangalore — 81%. The lower score reflects the higher density and complexity of the junction network, which produces more ambiguous walk profiles.*

![Kyiv road benchmark — 91% accuracy](docs/Kyiv.png)
*Kyiv — 91%. The river peninsula and wide arterials produce very distinct walk profiles, making localization easier.*

#### Off-trail wilderness benchmark

The off-trail benchmark works differently. Instead of random road walks, the tool generates walks shaped like **triangles, squares, rectangles, circles, and zigzags** across real terrain at dozens of random placements. The engine then tries to match each shape against the cached elevation map and find where it is.

The Great Smoky Mountains result below shows 54% accuracy. That number looks low next to the road results, but the comparison is not fair — the off-trail search covers roughly 89 km² with no prior on where the walk started. The road engine has the road network to pin it down; the off-trail engine has only the elevation profile.

![Great Smoky Mountains off-trail benchmark — 54%](docs/GreatSmoky.png)
*Great Smoky Mountains — 54% of shape walks located. Green outlines are successful localisations; red outlines are misses. The shape leaderboard (right panel) shows which walk shapes performed best at this specific terrain. Self-crossing shapes (the star and figure-eight) were universally the worst.*

**What the 54% actually means:** when the engine gets it right, it is often within tens of meters on a 3–5 km walk through mountainous terrain, using only a phone barometer. When it gets it wrong, the miss usually lands at a different location at the same elevation with a similar up-and-down profile — not a random guess, but a genuine terrain look-alike. This is a known and fundamental limitation of TERCOM when the search area is large and the terrain is repetitive. See the "Where this is going" section for how we plan to address it.

---

## Offline basemap (Protomaps and PMTiles)

There are no raster tiles and no tile server. When you download an area, the app runs `pmtiles extract` to pull just your bounding box out of the Protomaps daily cloud build into a single file at `data/areas/<slug>/basemap.pmtiles`. This is a few MB for a city and is fetched with HTTP range requests in a few seconds.

The browser renders it as **vector** tiles with MapLibre GL, so it stays crisp at every zoom level and keeps its labels. The server streams the file with HTTP range support. Everything the browser needs to render the map (MapLibre, the pmtiles protocol, the Protomaps theme, fonts, and the sprite) is vendored under `app/static/vendor/`, so the map works with no internet after the download.

If the `pmtiles` tool is not installed, the area still downloads and still **routes**. You just will not get a basemap, so the route draws on a blank canvas.

## Driving it with your phone (no GPS)

Your position only moves **while the phone reports motion**. Sit still, or send no telemetry, and the position holds. So it will not drive itself from your couch; you have to actually move. As you move and **stop** at intersections or lights, the Stationary Detection Engine snaps you to each node (you will see "NODE SNAPPED") and recalibrates speed.

There are two ways to stream your phone's sensors in. The Navigate screen prints the exact addresses once you press **Start navigation**.

### Option A: Sensor Logger over HTTP (iOS and Android, easiest)

1. Start the app so the phone can reach it, and note the LAN IP it prints:
   ```bash
   uv run python run_app.py --host 0.0.0.0
   ```
   Put the phone on the **same Wi-Fi**, or join the laptop to your phone's hotspot.
2. Install **Sensor Logger** (by Kelvin Choi). Enable the **Accelerometer**, **Gyroscope**, and **Magnetometer**. All three drive the sensor fusion: stop and go, turns, and drift-free heading.
3. In its settings, turn on **HTTP push / data streaming** and set the endpoint to the **`sensor_url`** shown in the heads-up display, for example `http://192.168.x.y:8080/api/sensor`.
4. Press **Start navigation**, then **start recording** in Sensor Logger. The display flips to `connected, moving/stopped`.

### Option B: a UDP sensor app (for example HyperIMU or SensorStream, Android)

Point its UDP stream at the **`phone_target`** shown in the display (`192.168.x.y:8000`) and send JSON of the form `{"accel_x":.., "accel_y":.., "accel_z":..}`. The UDP bridge listens on `0.0.0.0:8000` no matter which address the web server is bound to.

### No phone? Simulate it

Tick **Simulate phone** before starting. An in-process emulator streams real UDP accelerometer packets to the bridge and "stops" at each node, so you can watch the whole thing work end to end.

## How it works

```
 Browser (MapLibre GL + PMTiles)            Phone sensors (Sensor Logger)
        |  HTTP / JSON                              |  UDP :8000  {accel_x,y,z}
        v                                           v
   FastAPI server  ----------------------->  SensorBridge (background thread)
     /api/download  (osmnx graph + pmtiles)        |  rolling 1.5s variance
     /api/route     (networkx shortest path)       v
     /api/nav/*     (live session)          StationaryDetector -> SensorState
        |                                           |  is it stationary?
        v                                           v
   NavSession  ----------------------------> NavigationEngine
   (real-time dead reckoning; interpolates       (auto-snap within 50 m,
    position along the route; serves state)        70/30 speed smoothing)
```

The pieces:

- **`app/maps.py`**: geocodes the place, downloads the drivable road graph with `osmnx.graph_from_point`, and runs `pmtiles extract` to build the area's Protomaps basemap at `data/areas/<slug>/basemap.pmtiles`.
- **`app/routing.py`**: snaps clicked points to the nearest road nodes (using the haversine distance), finds the shortest path with `networkx`, and converts that path into the Anumaan `Milestone` array (real street names, node types, edge lengths, and speed limits).
- **`app/nav_session.py`**: runs the `NavigationEngine` and the `SensorBridge` along the route in real time, and exposes a state you can poll (position, speed, snaps, and packet counts).
- **`app/server.py`**: the FastAPI layer. It handles download jobs, the area list, basemap serving (with range requests), home, routing, and `nav/start`, `nav/state`, and `nav/stop`.
- **`app/static/`**: the MapLibre GL frontend. MapLibre, pmtiles.js, the Protomaps theme, fonts, and the sprite are all vendored locally so it works offline.
- **`anumaan/`**: the navigation core. It holds the `NavigationEngine` (dead reckoning, auto-snap, and speed smoothing), the Stationary Detection Engine (`sde.py`), and the UDP `SensorBridge` (`bridge.py`).

## The navigation engine (`anumaan/`)

This is a deterministic state machine, the same one from the original spec, now driving real routes. The core rules are:

- Expected travel time to the next milestone is dead-reckoned as `T_exp = distance / estimated_speed`.
- Phone sensor data arrives over UDP and is fed into the engine.
- A stop auto-snaps you to a node when the acceleration variance stays below 0.02 g for more than 1 second and you are within 50 m of that node.
- On each arrival, speed is smoothed with a 70/30 blend (70 percent old estimate, 30 percent new measurement).

Run its tests with:

```bash
uv run pytest           # tests cover the rules, the SDE, and the UDP bridge
```

## Project layout

```
app/
  maps.py          # OSM road graph download + Protomaps basemap extract
  routing.py       # nearest-node snap, shortest path, milestone conversion
  nav_session.py   # live navigation: engine + UDP bridge along the route
  server.py        # FastAPI endpoints + basemap and static serving
  static/          # MapLibre GL frontend (index.html, app.js, style.css)
  static/vendor/   # MapLibre, pmtiles.js, Protomaps theme, glyphs, sprite
anumaan/           # navigation engine, SDE, UDP sensor bridge
ios/               # the native iOS app (see ios/README.md)
run_app.py         # launches the web app
data/              # downloaded areas (graph + basemap) and saved home (gitignored)
tests/             # engine, SDE, and bridge tests
```

## Where this is going (future directions)

Anumaan already recovers your position two ways: by **snapping to roads** when you are on them, and by **matching the terrain** when you are not. The road case works well enough to be useful. The off-road case is the hard one, and it is where most of the upcoming work is aimed. Here is the plan, and what we have learned so far.

### The wilderness "Lost" mode

The goal is easy to state: someone is lost in the backcountry — a national park, a state forest — with no GPS, no signal, and often no marked trail under their feet. All they have is the phone's barometer, which gives the **change** in elevation but not the absolute height, and its compass. Can we still tell them where they are?

The idea is **terrain matching** — and strictly for demonstration purposes, this is the same technology used by Tomahawk cruise missiles (TERCOM: Terrain Contour Matching). A Tomahawk's altimeter measures the terrain below and matches it against a stored map of the planned corridor; when the two match, the missile knows exactly where it is. We are doing the same thing with a phone barometer and open elevation data from AWS. This prototype exists to explore how far that idea gets you with consumer hardware and open maps.

As you walk, the rise and fall of the ground traces out an elevation profile. If you have an offline elevation map of the area, you can slide that profile over the map and find the one spot where it fits. Where it fits is where you are.

To study this we built a **"simulate before you go" benchmark**, in the Map Simulator. You download a park once (this also caches its elevation tiles), choose **Off-trail**, and the tool runs the experiment for you. It lays out several walking **shapes** — a triangle, a square, a rectangle, a circle, and a zigzag — across the real terrain at many random spots, runs each one through the recovery engine, and reports two things: which shape gets you **found** most often, and how **accurately**. The best shape is not the same everywhere; it depends on the shape of the land. So the point is that you can run this for *your* park before you go, and learn what to walk if you get lost there.

What we have learned running it on real mountains (the Great Smokies, Yosemite):

- **It works, and it is fast.** On terrain with real relief, the engine locates a 3–5 km walk to within tens of meters, in under a second per walk.
- **But the result is split:** the engine is either dead-on, or wrong by kilometers, with little in between. The misses are not random. They land on a *different spot at the same elevation* that happens to have the same up-and-down pattern. Big mountains repeat themselves.
- **The deeper reason is that the search has too little to go on.** On a road you can only be *on the road*, so the set of possible positions is tiny and the engine gets to near-certainty. Off-trail you could be anywhere in the park, so a short elevation profile matches hundreds of spots almost equally well. Changing the walk shape helps a little, but it is a small knob; it cannot fix a search that has nothing pinning it down.

So the real work is **shrinking the set of places you could be**. Three planned ways to do that, in order of how much we expect each to help:

1. **Start from where you were last seen.** A lost hiker did not appear out of thin air in the middle of the park. They left a known trailhead or campsite and wandered some distance from it. Instead of searching the whole park, we will search a circle around that last-known point, and grow the circle slowly with the hours since they were last seen. This turns an impossible park-wide search into a small, solvable, local one.
2. **Combine several short walks instead of one long one.** The recovery engine was built to fuse many walks into a single, tighter estimate: walk a little, narrow the candidates, walk again, narrow them further. One blind walk is the weakest possible input; a handful of short ones, each cutting the field down, is far stronger.
3. **Use the compass.** An absolute heading (true north) rules out matches that only fit if you rotate them. Pinning the orientation removes a whole class of look-alike spots.

### Trail maps

The road approach works because the road network is a hard constraint: it forces your position onto a thin set of lines. Most wilderness is not truly roadless either. Parks are laced with **mapped hiking trails**, and OpenStreetMap already has them. The plan is to treat the **trail network the same way we treat roads** — download it with the area, and snap to it.

This helps in two ways. If a lost hiker stumbles onto *any* trail, even without knowing which one, we can pin them to the trail graph and recover their position the strong, road-style way. And even when they are off the trails, the nearby trail network shrinks the search: you are probably within some distance of a trail, not in the one truly trackless pocket of the map. Trail maps are the bridge between the road case that already works and the open-terrain case that is hard.

## Notes and limits

- The basemap is a single Protomaps `.pmtiles` file per area, extracted on download with the `pmtiles` tool. There are no raster tiles, no tile server, and no API key.
- Only one navigation session runs at a time, because there is a single UDP port (8000).
- This is dead-reckoning navigation. Accuracy depends on a sane initial speed and on actually stopping near nodes, so the Stationary Detection Engine can recalibrate.
