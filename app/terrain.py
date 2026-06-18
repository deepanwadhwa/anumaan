"""Read the elevation grid the Swift engine already downloaded, in Python.

The AnumaanSim binary caches a stitched Terrarium DEM per area as a tiny binary
blob (`~/Library/Caches/AnumaanSim/<area>/dem_<bounds>.bin`). Re-using that file
means the off-trail walk generator samples the *exact same* elevation data the
recovery engine fingerprints against — no extra download, no PNG decoding, and
no risk of the two sides disagreeing about the terrain.

Binary layout (little-endian), mirroring RealArea.writeDEM:
    int32   z, px0, py0, width, height        (web-mercator zoom + raster origin)
    float64 originLat, originLon              (local-meter frame origin; unused here)
    int16   elev[height * width]              (metres, row-major)

lat/lon -> pixel is the standard slippy-map projection (TileMath in DEMTiles.swift).
"""

from __future__ import annotations

import math
import random
import struct
from pathlib import Path

import numpy as np

CACHE_ROOT = Path.home() / "Library" / "Caches" / "AnumaanSim"

_METERS_PER_DEG_LAT = 111_320.0


class TerrariumDEM:
    """A stitched elevation raster with bilinear sampling by lat/lon."""

    def __init__(self, z: int, px0: int, py0: int, width: int, height: int,
                 elev: np.ndarray, origin_lat: float, origin_lon: float):
        self.z = z
        self.px0 = px0
        self.py0 = py0
        self.width = width
        self.height = height
        self.elev = elev.reshape(height, width).astype(np.float64)
        self.origin_lat = origin_lat
        self.origin_lon = origin_lon
        self._world_px = 256.0 * (1 << z)

    # ---- construction ------------------------------------------------------

    @classmethod
    def from_bin(cls, path: Path) -> "TerrariumDEM":
        data = path.read_bytes()
        if len(data) < 36:
            raise ValueError(f"DEM file too short: {path}")
        z, px0, py0, w, h = struct.unpack_from("<5i", data, 0)
        origin_lat, origin_lon = struct.unpack_from("<2d", data, 20)
        n = w * h
        if len(data) < 36 + 2 * n:
            raise ValueError(f"DEM file truncated: {path}")
        elev = np.frombuffer(data, dtype="<i2", count=n, offset=36)
        return cls(z, px0, py0, w, h, elev, origin_lat, origin_lon)

    # ---- projection --------------------------------------------------------

    def _global_px(self, lon: np.ndarray | float) -> np.ndarray | float:
        return (np.asarray(lon) + 180.0) / 360.0 * self._world_px

    def _global_py(self, lat: np.ndarray | float) -> np.ndarray | float:
        r = np.radians(np.asarray(lat))
        return (1.0 - np.arcsinh(np.tan(r)) / math.pi) / 2.0 * self._world_px

    # ---- sampling ----------------------------------------------------------

    def elevation(self, lat: float, lon: float) -> float | None:
        """Bilinearly sampled elevation (m) at a lat/lon, or None if off-grid."""
        fx = float(self._global_px(lon)) - self.px0
        fy = float(self._global_py(lat)) - self.py0
        if fx < 0 or fy < 0 or fx > self.width - 1 or fy > self.height - 1:
            return None
        x0, y0 = int(fx), int(fy)
        x1, y1 = min(x0 + 1, self.width - 1), min(y0 + 1, self.height - 1)
        tx, ty = fx - x0, fy - y0
        e = self.elev
        a = e[y0, x0] + (e[y0, x1] - e[y0, x0]) * tx
        b = e[y1, x0] + (e[y1, x1] - e[y1, x0]) * tx
        return float(a + (b - a) * ty)

    def elevation_many(self, lats: np.ndarray, lons: np.ndarray) -> np.ndarray:
        """Vectorised bilinear sample; off-grid points come back as NaN."""
        fx = self._global_px(lons) - self.px0
        fy = self._global_py(lats) - self.py0
        ok = (fx >= 0) & (fy >= 0) & (fx <= self.width - 1) & (fy <= self.height - 1)
        x0 = np.clip(fx.astype(int), 0, self.width - 1)
        y0 = np.clip(fy.astype(int), 0, self.height - 1)
        x1 = np.clip(x0 + 1, 0, self.width - 1)
        y1 = np.clip(y0 + 1, 0, self.height - 1)
        tx, ty = fx - x0, fy - y0
        e = self.elev
        a = e[y0, x0] + (e[y0, x1] - e[y0, x0]) * tx
        b = e[y1, x0] + (e[y1, x1] - e[y1, x0]) * tx
        out = a + (b - a) * ty
        out[~ok] = np.nan
        return out

    # ---- geography ---------------------------------------------------------

    def bounds(self) -> tuple[float, float, float, float]:
        """(south, west, north, east) covered by the raster, in degrees."""
        # invert the slippy-map projection at the raster corners
        def lon_of(px):
            return (self.px0 + px) / self._world_px * 360.0 - 180.0

        def lat_of(py):
            n = math.pi * (1 - 2 * (self.py0 + py) / self._world_px)
            return math.degrees(math.atan(math.sinh(n)))

        west, east = lon_of(0), lon_of(self.width - 1)
        north, south = lat_of(0), lat_of(self.height - 1)
        return south, west, north, east

    def meters_per_deg(self, lat: float) -> tuple[float, float]:
        """(metres per degree lat, metres per degree lon) at a latitude."""
        return _METERS_PER_DEG_LAT, _METERS_PER_DEG_LAT * math.cos(math.radians(lat))


def list_dem_caches(area_id: str) -> list[Path]:
    """All cached DEM blobs for an area, newest first."""
    d = CACHE_ROOT / area_id
    if not d.is_dir():
        return []
    return sorted(d.glob("dem_*.bin"), key=lambda p: p.stat().st_mtime, reverse=True)


def load_dem(area_id: str) -> TerrariumDEM:
    """Load the most-recently-downloaded DEM for an area."""
    caches = list_dem_caches(area_id)
    if not caches:
        raise FileNotFoundError(
            f"No cached DEM for area {area_id!r} under {CACHE_ROOT}. "
            "Download/run the area once so the engine fetches its terrain tiles."
        )
    return TerrariumDEM.from_bin(caches[0])


# ---- off-trail (wilderness) walk generation -------------------------------

class _Frame:
    """Local east/north metre frame around an area's centre + its DEM."""

    def __init__(self, dem: TerrariumDEM, south: float, west: float,
                 north: float, east: float):
        self.dem = dem
        self.clat = (south + north) / 2
        self.clon = (west + east) / 2
        self.m_lat, self.m_lon = dem.meters_per_deg(self.clat)
        # rectangle in metres relative to centre
        self.xmin = (west - self.clon) * self.m_lon
        self.xmax = (east - self.clon) * self.m_lon
        self.ymin = (south - self.clat) * self.m_lat
        self.ymax = (north - self.clat) * self.m_lat

    def lat_lon(self, x: float, y: float) -> tuple[float, float]:
        return self.clat + y / self.m_lat, self.clon + x / self.m_lon

    def elev(self, x: float, y: float) -> float | None:
        lat, lon = self.lat_lon(x, y)
        return self.dem.elevation(lat, lon)

    def inside(self, x: float, y: float) -> bool:
        return self.xmin <= x <= self.xmax and self.ymin <= y <= self.ymax


def _terrain_walk(
    frame: _Frame,
    rng: random.Random,
    min_distance_m: float,
    *,
    step_m: float,
    max_turn_deg: float,
    max_grade: float,
    elev_gain_budget_m: float,
    turniness: float,
    n_candidates: int = 7,
) -> dict | None:
    """One humanly-plausible off-trail meander, or None if it can't reach length.

    At each step we sample several candidate headings (a turn drawn from a
    gaussian whose width = ``turniness`` × ``max_turn_deg``), keep the ones that
    stay on terrain we can actually walk (grade ≤ ``max_grade``) and inside the
    rectangle and within the elevation-gain budget, then pick one weighted toward
    flatter ground. Terrain therefore bends the path (around steep faces, along
    valleys) while ``turniness`` controls how much curvature we inject.
    """
    margin = 150.0
    for _ in range(40):  # find a start with valid ground
        x = rng.uniform(frame.xmin + margin, frame.xmax - margin)
        y = rng.uniform(frame.ymin + margin, frame.ymax - margin)
        e0 = frame.elev(x, y)
        if e0 is not None:
            break
    else:
        return None

    heading = rng.uniform(0, 360)
    coords: list[list[float]] = [list(frame.lat_lon(x, y))]
    headings: list[float] = []
    elevs: list[float] = [e0]
    dist = 0.0
    gain = 0.0
    cur_e = e0
    sd = max(1.0, turniness * max_turn_deg)
    cap = int((min_distance_m / step_m) * 4) + 50

    for _ in range(cap):
        cands = []
        for _ in range(n_candidates):
            delta = max(-max_turn_deg, min(max_turn_deg, rng.gauss(0, sd)))
            h = heading + delta
            r = math.radians(h)
            nx, ny = x + math.sin(r) * step_m, y + math.cos(r) * step_m
            if not frame.inside(nx, ny):
                continue
            ne = frame.elev(nx, ny)
            if ne is None:
                continue
            grade = abs(ne - cur_e) / step_m
            climb = max(0.0, ne - cur_e)
            over_budget = (gain + climb) > elev_gain_budget_m
            cands.append((h, nx, ny, ne, delta, grade, climb, over_budget))

        if not cands:
            break  # boxed in by the rectangle / off-grid

        # Prefer walkable (low grade); avoid blowing the climb budget.
        def weight(c) -> float:
            _, _, _, _, _, grade, climb, over = c
            steep_pen = math.exp(-grade / max(0.05, max_grade))   # 1 flat → ~0 steep
            budget_pen = 0.15 if over else 1.0
            return steep_pen * budget_pen + 1e-6

        weights = [weight(c) for c in cands]
        h, nx, ny, ne, delta, grade, climb, over = rng.choices(cands, weights=weights)[0]

        heading = h
        gain += climb
        dist += step_m
        cur_e = ne
        x, y = nx, ny
        coords.append(list(frame.lat_lon(x, y)))
        headings.append(delta)
        elevs.append(ne)
        if dist >= min_distance_m:
            break

    if dist < min_distance_m or len(coords) < 2:
        return None
    return _terrain_metrics(coords, headings, elevs, dist)


def _terrain_metrics(coords, headings, elevs, dist) -> dict:
    arr = np.asarray(elevs, dtype=float)
    diffs = np.diff(arr)
    gain = float(np.clip(diffs, 0, None).sum())
    abs_change = float(np.abs(diffs).sum())
    net_elev = float(arr[-1] - arr[0])
    elev_range = float(arr.max() - arr.min())
    total_turn = float(sum(abs(d) for d in headings))
    km = max(dist / 1000.0, 1e-6)

    # net displacement / path length (1 = straight, ~0 = returns near start)
    a, b = coords[0], coords[-1]
    net = _METERS_PER_DEG_LAT * math.hypot(
        (b[0] - a[0]),
        (b[1] - a[1]) * math.cos(math.radians((a[0] + b[0]) / 2)),
    )
    straightness = round(net / dist, 3) if dist else 0.0

    # Where along the walk the climbing happens: fraction of total gain in the
    # first / middle / last third. Tests "does early vs mid vs late gain help?"
    g = np.clip(diffs, 0, None)
    n = max(1, len(g))
    third = max(1, n // 3)
    gtot = gain if gain > 0 else 1.0
    early = float(g[:third].sum()) / gtot
    mid = float(g[third:2 * third].sum()) / gtot
    late = float(g[2 * third:].sum()) / gtot

    return {
        "coords": coords,
        "distance_m": round(dist, 1),
        "elev_gain_m": round(gain, 1),
        "elev_range_m": round(elev_range, 1),
        "net_elev_m": round(net_elev, 1),
        # roughness: total up+down per km — high = "constantly changing terrain"
        "elev_roughness_m_per_km": round(abs_change / km, 1),
        # monotonicity: 1 = one steady climb/descent, ~0 = lots of up-and-down
        "monotonicity": round(abs(net_elev) / abs_change, 3) if abs_change > 0 else 0.0,
        "early_gain_frac": round(early, 3),
        "mid_gain_frac": round(mid, 3),
        "late_gain_frac": round(late, 3),
        "straightness": straightness,
        "total_heading_change_deg": round(total_turn, 1),
        "curvature_per_km": round(total_turn / km, 1),
    }


def _resample(points: list[tuple[float, float]], step_m: float) -> list[tuple[float, float]]:
    """Walk along a polyline emitting a point every step_m."""
    out = [points[0]]
    carry = 0.0
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        seg = math.hypot(x1 - x0, y1 - y0)
        if seg < 1e-9:
            continue
        ux, uy = (x1 - x0) / seg, (y1 - y0) / seg
        d = step_m - carry
        while d <= seg:
            out.append((x0 + ux * d, y0 + uy * d))
            d += step_m
        carry = seg - (d - step_m)
    return out


def _polyline_length(pts: list[tuple[float, float]]) -> float:
    return sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(pts, pts[1:]))


# Self-crossing shapes (figure_eight, star) are excluded: across parks they alias
# catastrophically (misses of 2-9 km onto look-alike ridges). Their outlines are
# still defined below in case of explicit use, but they're not benchmarked.
SHAPE_TYPES = ["triangle", "square", "rectangle", "circle", "zigzag"]


def _shape_outline(shape: str, zigzag_angle_deg: float = 30.0,
                   zigzag_legs: int = 6) -> list[tuple[float, float]]:
    """A unit-scale outline for a shape, as a dense (x, y) polyline.

    ``zigzag_angle_deg`` is the leg's angle off the line of travel: 0° = straight,
    90° = folded back on itself. Small = an open, advancing zigzag that spreads
    across terrain; large = a tight back-and-forth that barely advances.
    """
    if shape == "triangle":            # equilateral
        c = [(0.0, 0.0), (1.0, 0.0), (0.5, math.sqrt(3) / 2)]
        return c + [c[0]]
    if shape == "square":
        c = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
        return c + [c[0]]
    if shape == "rectangle":           # 2:1
        c = [(0.0, 0.0), (2.0, 0.0), (2.0, 1.0), (0.0, 1.0)]
        return c + [c[0]]
    if shape == "circle":
        return [(math.cos(t), math.sin(t))
                for t in (i / 240 * 2 * math.pi for i in range(241))]
    if shape == "figure_eight":        # lemniscate of Gerono, a clean ∞
        return [(math.sin(t), math.sin(t) * math.cos(t))
                for t in (i / 480 * 2 * math.pi for i in range(481))]
    if shape == "zigzag":              # sawtooth transect; sharpness = zigzag_angle_deg
        a = math.radians(max(1.0, min(89.0, zigzag_angle_deg)))
        dx, dy = math.cos(a), math.sin(a)
        pts = [(0.0, 0.0)]
        x = y = 0.0
        for k in range(zigzag_legs):
            x += dx
            y += dy if k % 2 == 0 else -dy
            pts.append((x, y))
        return pts
    if shape == "star":                # 5-point pentagram (long crossing legs, wide spread)
        outer = [(math.cos(math.radians(90 + 72 * i)),
                  math.sin(math.radians(90 + 72 * i))) for i in range(5)]
        return [outer[i] for i in (0, 2, 4, 1, 3, 0)]
    raise ValueError(f"unknown shape {shape!r}")


def generate_shape_walks(
    dem: TerrariumDEM,
    south: float, west: float, north: float, east: float,
    shapes: list[str],
    target_len_m: float,
    placements: int,
    *,
    seed: int | None = None,
    step_m: float = 20.0,
    max_place_attempts: int = 60,
    zigzag_angle_deg: float = 30.0,
) -> list[dict]:
    """Lay each shape on the terrain at several random spots/rotations.

    Each shape is scaled so its walked perimeter ≈ target_len_m, dropped at a
    random in-bounds location with a random rotation, then sampled against the
    real DEM. We compare which shape's curvature+elevation fingerprint is most
    uniquely localizable. Returns walk dicts (same shape as terrain walks, plus
    a "shape" tag).
    """
    frame = _Frame(dem, south, west, north, east)
    rng = random.Random(seed)
    walks: list[dict] = []

    for shape in shapes:
        outline = _shape_outline(shape, zigzag_angle_deg=zigzag_angle_deg)
        length0 = _polyline_length(outline)
        scale = target_len_m / length0
        base = _resample([(x * scale, y * scale) for x, y in outline], step_m)
        # centre the shape on its own centroid so rotation/placement is stable
        cx = sum(p[0] for p in base) / len(base)
        cy = sum(p[1] for p in base) / len(base)
        base = [(x - cx, y - cy) for x, y in base]
        rx = max(abs(p[0]) for p in base)
        ry = max(abs(p[1]) for p in base)

        made = 0
        for _ in range(max_place_attempts):
            if made >= placements:
                break
            theta = rng.uniform(0, 2 * math.pi)
            ct, st = math.cos(theta), math.sin(theta)
            rad = math.hypot(rx, ry) + 50.0
            ox = rng.uniform(frame.xmin + rad, frame.xmax - rad)
            oy = rng.uniform(frame.ymin + rad, frame.ymax - rad)
            if frame.xmax - rad <= frame.xmin + rad or frame.ymax - rad <= frame.ymin + rad:
                break  # shape too big for this area

            pts = [(ox + (x * ct - y * st), oy + (x * st + y * ct)) for x, y in base]
            elevs = [frame.elev(px, py) for px, py in pts]
            if any(e is None for e in elevs):
                continue  # ran off the DEM, try another placement

            coords = [list(frame.lat_lon(px, py)) for px, py in pts]
            headings = []
            for a, b, c in zip(pts, pts[1:], pts[2:]):
                h1 = math.degrees(math.atan2(b[0] - a[0], b[1] - a[1]))
                h2 = math.degrees(math.atan2(c[0] - b[0], c[1] - b[1]))
                d = (h2 - h1 + 180) % 360 - 180
                headings.append(d)
            dist = _polyline_length(pts)
            m = _terrain_metrics(coords, headings, elevs, dist)
            m["shape"] = shape
            walks.append(m)
            made += 1

    return walks


def generate_terrain_walks(
    dem: TerrariumDEM,
    south: float, west: float, north: float, east: float,
    num_walks: int,
    min_distance_m: float,
    *,
    seed: int | None = None,
    step_m: float = 20.0,
    max_turn_deg: float = 40.0,
    max_grade: float = 0.5,
    elev_gain_budget_m: float = 500.0,
    turniness: float = 0.6,
    max_attempts_per_walk: int = 25,
) -> list[dict]:
    """Generate ``num_walks`` off-trail meanders of at least ``min_distance_m``.

    Constraints keep each walk humanly possible: a per-step turn ceiling, a slope
    ceiling (``max_grade`` ≈ rise/run, 0.5 ≈ 27°), and a total climb budget
    (``elev_gain_budget_m``). ``turniness`` (0–1) trades straight efficiency for
    curvature — the lever for maximising per-km curvature uniqueness.
    """
    frame = _Frame(dem, south, west, north, east)
    rng = random.Random(seed)
    walks: list[dict] = []
    for _ in range(num_walks):
        for _ in range(max_attempts_per_walk):
            w = _terrain_walk(
                frame, rng, min_distance_m,
                step_m=step_m, max_turn_deg=max_turn_deg, max_grade=max_grade,
                elev_gain_budget_m=elev_gain_budget_m, turniness=turniness,
            )
            if w is not None:
                walks.append(w)
                break
    return walks
