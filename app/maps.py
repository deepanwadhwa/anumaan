"""Map acquisition: OSM road graph + a Protomaps PMTiles basemap for an area.

Downloading is the one online step; afterwards everything is local:

  data/areas/<slug>/
      graph.graphml      # road network for routing (networkx via osmnx)
      basemap.pmtiles    # offline vector basemap (Protomaps), one file
      meta.json          # center, radius, bbox, counts

The basemap is extracted for the area's bounding box out of the Protomaps daily
cloud build with the `pmtiles` CLI — a few MB per city, rendered offline by
MapLibre GL in the browser.
"""

from __future__ import annotations

import json
import math
import re
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import osmnx as ox
import requests

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
AREAS_DIR = DATA_DIR / "areas"

USER_AGENT = "Anumaan-OfflineNav/1.0 (personal offline navigation project)"
# Protomaps daily basemap builds live at this dated URL; we resolve the newest
# available one by probing backwards from today.
PROTOMAPS_BUILD_URL = "https://build.protomaps.com/{date}.pmtiles"

ProgressFn = Callable[[str, float], None]


def _noop(_msg: str, _frac: float) -> None:
    pass


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
def slugify(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s or "area"


def geocode(query: str) -> tuple[float, float]:
    """Resolve a free-form place ("Austin, Texas, USA") to (lat, lon)."""
    lat, lon = ox.geocode(query)
    return float(lat), float(lon)


def bbox_from_point(lat: float, lon: float, radius_m: float) -> tuple[float, float, float, float]:
    """Return (north, south, east, west) for a square around the point."""
    dlat = radius_m / 111_320.0
    dlon = radius_m / (111_320.0 * max(math.cos(math.radians(lat)), 1e-6))
    return lat + dlat, lat - dlat, lon + dlon, lon - dlon


def pmtiles_available() -> bool:
    return shutil.which("pmtiles") is not None


def latest_build_url(probe_days: int = 14) -> str:
    """Find the most recent Protomaps daily build by probing backwards.

    Uses a tiny ranged GET (one byte) so we don't download anything.
    """
    from datetime import date, timedelta

    session = requests.Session()
    session.headers["User-Agent"] = USER_AGENT
    today = date.today()
    for i in range(probe_days):
        d = (today - timedelta(days=i)).strftime("%Y%m%d")
        url = PROTOMAPS_BUILD_URL.format(date=d)
        try:
            r = session.get(url, headers={"Range": "bytes=0-0"}, timeout=10)
            if r.status_code in (200, 206):
                return url
        except requests.RequestException:
            continue
    raise RuntimeError("could not reach any recent Protomaps build")


# --------------------------------------------------------------------------
# area model
# --------------------------------------------------------------------------
@dataclass
class Area:
    slug: str
    name: str
    lat: float
    lon: float
    radius_m: float
    bbox: tuple[float, float, float, float]   # (north, south, east, west)
    node_count: int = 0
    edge_count: int = 0
    has_basemap: bool = False
    basemap_bytes: int = 0
    created: float = 0.0

    @property
    def dir(self) -> Path:
        return AREAS_DIR / self.slug

    def to_dict(self) -> dict:
        d = {k: getattr(self, k) for k in (
            "slug", "name", "lat", "lon", "radius_m", "bbox",
            "node_count", "edge_count", "has_basemap", "basemap_bytes", "created")}
        d["bbox"] = list(self.bbox)
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "Area":
        fields = set(cls.__dataclass_fields__)
        kw = {k: v for k, v in d.items() if k in fields}
        kw["bbox"] = tuple(kw["bbox"])
        return cls(**kw)


def list_areas() -> list[dict]:
    areas = []
    if not AREAS_DIR.exists():
        return areas
    for meta in sorted(AREAS_DIR.glob("*/meta.json")):
        try:
            d = json.loads(meta.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        slug = d.get("slug", meta.parent.name)
        d["has_basemap"] = (meta.parent / "basemap.pmtiles").exists()
        areas.append(d)
    return areas


def load_area(slug: str) -> Area | None:
    meta = AREAS_DIR / slug / "meta.json"
    if not meta.exists():
        return None
    return Area.from_dict(json.loads(meta.read_text()))


# --------------------------------------------------------------------------
# basemap extraction (Protomaps)
# --------------------------------------------------------------------------
def extract_basemap(bbox, out_path: Path, *, build_url: str | None = None,
                    progress: ProgressFn = _noop) -> int:
    """Extract the area's vector basemap from the Protomaps cloud build.

    Returns the size in bytes of the written ``basemap.pmtiles``.
    """
    if not pmtiles_available():
        raise RuntimeError(
            "the 'pmtiles' CLI is not installed — run `brew install pmtiles`")
    north, south, east, west = bbox
    build_url = build_url or latest_build_url()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = out_path.with_suffix(".tmp.pmtiles")
    progress("extracting Protomaps basemap for the area…", 0.0)
    # pmtiles extract <src> <out> --bbox=W,S,E,N
    proc = subprocess.run(
        ["pmtiles", "extract", build_url, str(tmp),
         f"--bbox={west},{south},{east},{north}"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        tmp.unlink(missing_ok=True)
        raise RuntimeError(f"pmtiles extract failed: {proc.stderr.strip()[-400:]}")
    tmp.replace(out_path)
    size = out_path.stat().st_size
    progress(f"basemap ready ({size // 1024} KB)", 1.0)
    return size


# --------------------------------------------------------------------------
# top-level download: road graph + basemap
# --------------------------------------------------------------------------
def download_area(
    name: str,
    lat: float,
    lon: float,
    radius_m: float,
    *,
    progress: ProgressFn = _noop,
    build_url: str | None = None,
) -> Area:
    """Download the road network and extract the Protomaps basemap for an area."""
    slug = slugify(f"{name}-{round(lat,3)}-{round(lon,3)}-{int(radius_m)}m")
    area_dir = AREAS_DIR / slug
    area_dir.mkdir(parents=True, exist_ok=True)

    progress("downloading road network from OpenStreetMap…", 0.05)
    graph = ox.graph_from_point((lat, lon), dist=radius_m, network_type="drive")
    ox.save_graphml(graph, area_dir / "graph.graphml")
    progress(f"road network: {graph.number_of_nodes()} nodes", 0.4)

    bbox = bbox_from_point(lat, lon, radius_m)
    basemap_bytes = 0
    has_basemap = False
    try:
        basemap_bytes = extract_basemap(
            bbox, area_dir / "basemap.pmtiles", build_url=build_url,
            progress=lambda m, f: progress(m, 0.4 + 0.6 * f))
        has_basemap = True
    except RuntimeError as exc:
        # Routing still works without a basemap; surface the reason and continue.
        progress(f"basemap skipped: {exc}", 1.0)

    area = Area(
        slug=slug, name=name, lat=lat, lon=lon, radius_m=radius_m, bbox=bbox,
        node_count=graph.number_of_nodes(), edge_count=graph.number_of_edges(),
        has_basemap=has_basemap, basemap_bytes=basemap_bytes, created=time.time(),
    )
    (area_dir / "meta.json").write_text(json.dumps(area.to_dict(), indent=2))
    progress("done", 1.0)
    return area
