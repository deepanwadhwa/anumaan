# Anumaan

Anumaan (Hindi: अनुमान) means "to estimate", "to deduce", "to reckon roughly". This is a working prototype exploring how far you can get with navigation without GPS.

## The problem we are trying to solve

GPS-free navigation sounds hard, but the core requirements are actually pretty narrow. To route someone from point A to point B without GPS, you need three things:

1. **An offline map** with routing built in, so you can run A* or any shortest-path algorithm without a network connection.
2. **A starting position** on that map, so you know where to begin.
3. **A speed estimate**, so you can predict when you will reach the next known landmark.

If you have all three, you can dead-reckon your way through a road network with reasonable accuracy: the app knows where you started, how fast you are moving, and which roads you are on, so it can estimate when you will arrive at the next intersection.

The hard one is speed. On a phone with no GPS, there is no direct speed measurement. The clean solution would be an OBD dongle plugged into the car's data port, or a smart car that broadcasts its speed over Bluetooth. I had neither of those. So I did the next best thing: **assume you are driving at the speed limit**, which the map already knows for every road segment.

That assumption is good enough to get the timing right within a few seconds on a typical city block. And the app does not just trust that assumption blindly. Every time you approach a mapped intersection, the app asks: *"Have you reached this intersection yet?"* Your yes or no corrects the position estimate. If your phone's barometer and motion sensors also detect the terrain change expected at that point, the app can confirm the snap automatically without asking.

That question-and-answer loop is the core of the road navigation engine. Each answered question narrows the set of places you could be, and after a few intersections the position converges to a tight cluster.

### But road navigation already has a simpler answer

It is worth being honest about this: if you are lost on a road, you have an easier option than any of the above. Look at the nearest street sign, type it into an offline map, and it tells you exactly where you are. Done.

This repository is not trying to compete with that. The road work was a first step, a way to build and validate the underlying localization engine before pointing it at the genuinely hard problem. The hard problem is what happens when there is no street sign, no road, and nothing around you but terrain.

### The wilderness problem

Off-road navigation is where TERCOM (Terrain Contour Matching) becomes the only real tool available. As you walk, the rise and fall of the ground traces out an elevation profile. If you have a cached offline elevation map of the area, you can compare that profile against every possible location and find where it fits best.

This is the same principle behind the guidance system in a Tomahawk cruise missile. The missile's altimeter measures the terrain below, and the onboard map records the pre-planned corridor; when the two align, the missile knows exactly where it is. We are doing a simpler version of the same thing with a phone barometer and open elevation data. This repository is, strictly speaking, a demonstration of how far that idea gets you with consumer hardware and open maps.

What makes it hard is that big terrain repeats itself. A 3 km walk at 1,400 m elevation on a south-facing slope in the Smokies might look almost identical to a different 3 km walk at the same elevation on a different south-facing slope 8 km away. The engine either nails it or lands on one of these look-alikes, with little in between. The benchmarks below show that split clearly.

---

## What is in this repo

- **iOS app (`ios/`)** is a native Swift app with three screens: **Navigate** (follow a route by dead reckoning), **Track** (record a walk), and **Lost** (recover your position from the terrain with TERCOM). We built this so we could take a phone outside and test whether the dead-reckoning and terrain-matching ideas hold up in the real world. See [`ios/README.md`](ios/README.md) to build and run it.
- **Map Simulator** (`/sim`) lets you draw walk paths on a map, synthesize walk telemetry (noisy barometer and heading), and run the Swift recovery engine (`AnumaanSim` CLI) to visualize the particle filter and Q&A engine converging onto your true position. It also includes a **Region Benchmarker** that runs hundreds of synthetic walks across a downloaded area and scores how often the engine recovers the correct position.

## Run the simulator

This project uses [uv](https://docs.astral.sh/uv/) and the [`pmtiles`](https://docs.protomaps.com/pmtiles/cli) command line tool. Install both once:

```bash
brew install uv pmtiles
uv sync                       # create the environment and install deps from uv.lock
uv run python run_app.py      # serves on http://127.0.0.1:8080
```

Open http://127.0.0.1:8080/sim in a browser.

1. **Download an area.** Use the geocoding search to find a location, then click **Download Current View**. This downloads the OSM road network and AWS elevation tiles for the bounding box.
2. **Choose a mode.** Paved Roads uses the road-snapping particle filter. Off-Trail uses terrain-contour TERCOM matching.
3. **Draw and run.** Click the map to draw a walk path (at least 2 waypoints), then click **Run Sim**.
4. **Answer questions.** The simulator asks Yes/No questions about landmarks along the path. Watch the hypothesis cloud (orange dots) narrow down to the true location (pink marker).
5. **Run a benchmark.** Switch to the **Region Benchmarker** tab to run hundreds of walks automatically and see aggregate accuracy, median error, and per-walk statistics on the map.

## Benchmark results

### Road localization

The road engine performs well on dense road networks. These runs used a strict trail walk style (paths that never reuse a street segment), a minimum walk distance of 3 km, and randomized Q&A (1 to 4 questions per walk).

| Area | Accuracy | Notes |
|---|---|---|
| Clemson, SC | **90%** | Mixed suburban/rural grid |
| Buffalo, NY | **89%** | Dense urban grid |
| Bangalore, India | **81%** | Complex junction-heavy layout |
| Kyiv, Ukraine | **91%** | Wide arterials, river peninsula |

The numbers are not 100% because some walks are genuinely ambiguous: two streets of the same length and orientation are hard to tell apart from motion sensors alone.

![Clemson road benchmark — 90% accuracy](docs/Clemson.png)
*Clemson, SC. 90% of 197 strict-trail walks located to within 13 m median error.*

![Buffalo road benchmark — 89% accuracy](docs/Buffalo.png)
*Buffalo, NY. 89% accuracy on a dense urban grid. Red dots show the small cluster of misses near the southern boundary.*

![Bangalore road benchmark — 81% accuracy](docs/Bangalore.png)
*Bangalore. 81%. The higher junction density produces more ambiguous walk profiles.*

![Kyiv road benchmark — 91% accuracy](docs/Kyiv.png)
*Kyiv. 91%. The river peninsula and wide arterials give very distinct walk profiles.*

### Off-trail wilderness

The off-trail benchmark generates walks shaped like triangles, squares, rectangles, circles, and zigzags across real terrain at dozens of random placements. The engine tries to match each shape against the cached elevation map.

The Great Smoky Mountains result below shows 54%. The off-trail search covers roughly 89 km² with no prior on where the walk started, which is why this is hard: the engine has to search the whole park. When it gets it right, it is often within tens of meters on a 3 to 5 km walk using only a phone barometer. When it gets it wrong, the miss lands at a different location at the same elevation with a similar up-and-down profile. This is not a random guess but a genuine terrain look-alike, and it is a known fundamental limitation of TERCOM on repetitive terrain. See the "Where this is going" section for how we plan to address it.

![Great Smoky Mountains off-trail benchmark — 54%](docs/GreatSmoky.png)
*Great Smoky Mountains. 54% of shape walks located. Green outlines are successful localisations; red outlines are misses. The shape leaderboard (right panel) shows which walk shapes performed best on this specific terrain. Self-crossing shapes (star and figure-eight) were universally the worst.*

---

## Project layout

```
ios/               # native Swift app (Navigate, Track, Lost screens)
app/
  sim.py           # benchmark runner, walk generator, off-trail engine dispatch
  terrain.py       # DEM reader, shape walk generator, terrain metrics
  routing.py       # road graph download, walk generator, coverage metrics
  server.py        # FastAPI server for the simulator
  static/sim.html  # simulator UI (MapLibre GL)
  static/vendor/   # MapLibre, pmtiles.js, Protomaps theme (vendored, offline)
data/              # downloaded areas, road graphs, DEM tiles (gitignored)
docs/              # benchmark screenshots
```

## Where this is going

The road case works well enough to be useful. The off-road case is the hard one, and it is where most of the upcoming work is aimed.

### The wilderness "Lost" mode

The goal is easy to state: someone is lost in the backcountry with no GPS, no signal, and often no marked trail under their feet. All they have is the phone's barometer, which gives the change in elevation but not the absolute height, and its compass. Can we still tell them where they are?

To study this we built a "simulate before you go" benchmark in the Map Simulator. You download a park (which caches its elevation tiles), choose Off-trail, and the tool runs the experiment for you. It lays out several walking shapes across the real terrain at many random spots, runs each one through the recovery engine, and reports which shape gets you found most often and how accurately. The best shape is not the same everywhere; it depends on the shape of the land. The idea is that you run this for your park before you go, and you learn what to walk if you get lost there.

What we have learned from running it on the Great Smokies and Yosemite:

- On terrain with real relief, the engine locates a 3 to 5 km walk to within tens of meters, in under a second per walk.
- But the result is bimodal: dead-on or wrong by kilometers, with little in between. The misses land on a different spot at the same elevation that happens to have the same up-and-down pattern.
- Changing the walk shape helps at the margin, but it cannot fix a search that has nothing pinning it down.

The real fix is shrinking the set of places the person could be. Three planned approaches, in order of expected impact:

1. **Start from where they were last seen.** A lost hiker left a known trailhead or campsite. Search a circle around that point and grow it slowly with elapsed time. This turns a park-wide search into a small, solvable, local one.
2. **Fuse several short walks.** Walk a little, narrow the candidates, walk again, narrow further. One walk is the weakest possible input; a handful is far stronger.
3. **Use the compass.** An absolute heading rules out matches that only fit if you rotate them. Pinning the orientation removes a whole class of look-alike spots.

### Trail maps

Parks are laced with mapped hiking trails and OpenStreetMap already has them. The plan is to treat the trail network the same way we treat roads: download it with the area and snap to it.

If a lost hiker stumbles onto any trail, even without knowing which one, we can pin them to the trail graph and recover their position the same strong way the road engine works. And even off the trails, the nearby trail network shrinks the search. Trail maps are the bridge between the road case that already works and the open-terrain case that is still hard.

## Notes

- The off-trail engine requires the release build of `AnumaanSim` (`swift build -c release` inside `ios/`). The debug build is too slow for the DTW search over the full terrain grid.
- The basemap is a single Protomaps `.pmtiles` file per area extracted with the `pmtiles` tool. No tile server, no API key.
- This is a demonstration and research prototype, not a production navigation system.
