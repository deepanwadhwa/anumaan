# Anumaan

Anumaan is a navigation system that works without GPS. The name (Hindi: अनुमान) means "to deduce" or "to reckon roughly", which is exactly what it does. Instead of reading a GPS fix, it figures out where you are by **dead reckoning**: it keeps a running estimate of how far you have moved and in which direction, using only the phone's motion sensors (accelerometer, gyroscope, magnetometer).

On roads, it snaps that estimate to the nearest road node every time you stop, so small errors do not pile up. Off roads, where there is nothing to snap to, it recovers your position by matching the shape of the terrain around you against an offline elevation map. That terrain matching is called **TERCOM** (Terrain Contour Matching).

Everything runs offline. The only step that needs the internet is downloading the map for an area before you go.

## What is in this repo

There are two implementations of the same idea.

- **iOS app (`ios/`)** is the real product. It is a native Swift app that runs entirely on the phone, with no server and no network once an area is downloaded. It has three screens: **Navigate** (follow a route by dead reckoning), **Track** (record a walk), and **Lost** (recover your position from the terrain with TERCOM). See [`ios/README.md`](ios/README.md) to build and run it.
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

## Notes and limits

- The basemap is a single Protomaps `.pmtiles` file per area, extracted on download with the `pmtiles` tool. There are no raster tiles, no tile server, and no API key.
- Only one navigation session runs at a time, because there is a single UDP port (8000).
- This is dead-reckoning navigation. Accuracy depends on a sane initial speed and on actually stopping near nodes, so the Stationary Detection Engine can recalibrate.
