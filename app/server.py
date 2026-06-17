"""FastAPI server for the Anumaan local navigation app.

Serves the MapLibre frontend, the offline Protomaps basemap (PMTiles), and the
JSON API for: downloading areas, listing/deleting them, setting home, routing,
and running live navigation off the phone's IMU via the UDP bridge.
"""

from __future__ import annotations

import json
import socket
import threading
import uuid
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from . import maps, routing, sim
from .nav_session import session

app = FastAPI(title="Anumaan Offline Navigation")

STATIC_DIR = Path(__file__).resolve().parent / "static"
maps.AREAS_DIR.mkdir(parents=True, exist_ok=True)

# In-memory download jobs: job_id -> progress dict.
JOBS: dict[str, dict] = {}
HOME_FILE = maps.DATA_DIR / "home.json"


def local_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


# ---- request models -------------------------------------------------------
class GeocodeReq(BaseModel):
    query: str


class DownloadReq(BaseModel):
    name: str
    query: str | None = None
    lat: float | None = None
    lon: float | None = None
    radius_m: float = 3000.0


class HomeReq(BaseModel):
    slug: str
    lat: float
    lon: float
    label: str = "Home"


class RouteReq(BaseModel):
    slug: str
    start: list[float]
    dest: list[float]


class NavStartReq(BaseModel):
    slug: str
    start: list[float]
    dest: list[float]
    speed: float = 11.0
    simulate: bool = False


# ---- pages & static -------------------------------------------------------
@app.get("/")
def index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


# ---- geocode + download ---------------------------------------------------
@app.post("/api/geocode")
def api_geocode(req: GeocodeReq) -> dict:
    try:
        lat, lon = maps.geocode(req.query)
    except Exception as exc:  # noqa: BLE001 - surface geocoder failures
        raise HTTPException(404, f"could not find '{req.query}': {exc}")
    return {"lat": lat, "lon": lon}


def _run_download(job_id: str, req: DownloadReq) -> None:
    job = JOBS[job_id]

    def progress(message: str, frac: float) -> None:
        job["message"] = message
        job["frac"] = round(frac, 3)

    try:
        if req.lat is None or req.lon is None:
            if not req.query:
                raise ValueError("provide a place query or lat/lon")
            progress(f"locating '{req.query}'…", 0.0)
            lat, lon = maps.geocode(req.query)
        else:
            lat, lon = req.lat, req.lon
        area = maps.download_area(req.name, lat, lon, req.radius_m, progress=progress)
        job["area"] = area.to_dict()
        job["done"] = True
    except Exception as exc:  # noqa: BLE001
        job["error"] = str(exc)
        job["done"] = True


@app.post("/api/download")
def api_download(req: DownloadReq) -> dict:
    job_id = uuid.uuid4().hex[:12]
    JOBS[job_id] = {"message": "starting…", "frac": 0.0, "done": False,
                    "error": None, "area": None}
    threading.Thread(target=_run_download, args=(job_id, req), daemon=True).start()
    return {"job_id": job_id}


@app.get("/api/download/{job_id}")
def api_download_status(job_id: str) -> dict:
    job = JOBS.get(job_id)
    if job is None:
        raise HTTPException(404, "unknown job")
    return job


# ---- areas ----------------------------------------------------------------
@app.get("/api/areas")
def api_areas() -> dict:
    return {"areas": maps.list_areas()}


@app.delete("/api/areas/{slug}")
def api_delete_area(slug: str) -> dict:
    import shutil
    d = maps.AREAS_DIR / slug
    if not d.exists():
        raise HTTPException(404, "no such area")
    shutil.rmtree(d)
    routing.load_graph.cache_clear()
    return {"ok": True}


# ---- offline basemap (Protomaps PMTiles, served with HTTP range) ----------
@app.get("/areas/{slug}/basemap.pmtiles")
def api_basemap(slug: str):
    path = maps.AREAS_DIR / slug / "basemap.pmtiles"
    if not path.exists():
        raise HTTPException(404, "no basemap for this area")
    # FileResponse honours Range requests, which is how pmtiles.js reads it.
    return FileResponse(path, media_type="application/octet-stream")


# ---- home -----------------------------------------------------------------
@app.get("/api/home")
def api_get_home() -> dict:
    if HOME_FILE.exists():
        return json.loads(HOME_FILE.read_text())
    return {}


@app.post("/api/home")
def api_set_home(req: HomeReq) -> dict:
    HOME_FILE.write_text(json.dumps(req.model_dump(), indent=2))
    return {"ok": True, **req.model_dump()}


# ---- routing --------------------------------------------------------------
@app.post("/api/route")
def api_route(req: RouteReq) -> dict:
    try:
        route = routing.compute_route(req.slug, tuple(req.start), tuple(req.dest))
    except (ValueError, FileNotFoundError) as exc:
        raise HTTPException(400, str(exc))
    route.pop("_milestone_objs", None)
    return route


# ---- phone telemetry (HTTP push, e.g. Sensor Logger) ----------------------
@app.post("/api/sensor")
async def api_sensor(request: Request) -> dict:
    """Ingest an HTTP-posted accelerometer body into the live nav session.

    Accepts Sensor Logger's batch JSON (or a single {accel_x,y,z}). Only does
    anything while navigation is running.
    """
    body = await request.body()
    packets = session.ingest(body)
    return {"ok": True, "packets": packets}


def _targets(request: Request) -> dict:
    ip = local_ip()
    port = request.url.port or 80
    return {
        "phone_target": f"{ip}:{session.port}",            # UDP apps
        "sensor_url": f"http://{ip}:{port}/api/sensor",     # Sensor Logger (HTTP)
    }


# ---- navigation -----------------------------------------------------------
@app.post("/api/nav/start")
def api_nav_start(req: NavStartReq, request: Request) -> dict:
    try:
        route = routing.compute_route(req.slug, tuple(req.start), tuple(req.dest))
    except (ValueError, FileNotFoundError) as exc:
        raise HTTPException(400, str(exc))
    state = session.start(route, speed=req.speed, simulate=req.simulate)
    state.update(_targets(request))
    return state


@app.get("/api/nav/state")
def api_nav_state(request: Request) -> dict:
    state = session.state()
    state.update(_targets(request))
    return state


@app.post("/api/nav/advance")
def api_nav_advance() -> dict:
    """Manual 'I've already reached the next milestone' — snap forward."""
    return {"ok": session.request_advance()}


@app.post("/api/nav/stop")
def api_nav_stop() -> dict:
    session.stop()
    return {"ok": True}


# ---- simulation -----------------------------------------------------------

@app.get("/sim")
def sim_page() -> FileResponse:
    return FileResponse(STATIC_DIR / "sim.html")


@app.get("/api/sim/areas")
def api_sim_areas() -> dict:
    return {"areas": sim.AREAS}


class DownloadRequest(BaseModel):
    south: float
    west: float
    north: float
    east: float
    name: str


@app.post("/api/sim/download")
def api_sim_download(req: DownloadRequest) -> dict:
    area_id = req.name.lower().replace(" ", "_")
    area_id = "".join(c for c in area_id if c.isalnum() or c == "_")
    
    sim.AREAS[area_id] = {
        "south": req.south,
        "west": req.west,
        "north": req.north,
        "east": req.east,
        "center": [(req.south + req.north) / 2, (req.west + req.east) / 2],
        "zoom": 14,
        "name": req.name,
    }
    sim.save_areas()
    
    # Trigger Swift simulator with a dummy walk to download & cache the OSM roads and DEM tiles.
    center_lat = (req.south + req.north) / 2
    center_lon = (req.west + req.east) / 2
    dummy_path = [
        [center_lat - 0.001, center_lon - 0.001],
        [center_lat + 0.001, center_lon + 0.001]
    ]
    
    try:
        sim.run_sim(sim.SimRequest(area=area_id, path=dummy_path, mode="road"))
    except Exception:
        pass
        
    return {"status": "ok", "area_id": area_id, "name": req.name, "area": sim.AREAS[area_id]}


@app.post("/api/simulate")
def api_simulate(req: sim.SimRequest) -> dict:
    return sim.run_sim(req)


# Mount static last so it doesn't shadow API routes.
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
