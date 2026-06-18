"""Routing over a downloaded OSM road graph, and conversion to milestones.

Snaps two clicked points to the nearest road-network nodes, finds the
shortest path with networkx, and turns that path into:

  * a dense ``coords`` polyline (following real road geometry) for drawing, and
  * a ``Milestone`` array (one per graph node on the path) for the Anumaan engine.
"""

from __future__ import annotations

import math
import random
import re
from functools import lru_cache

import networkx as nx
import osmnx as ox

from anumaan.models import Milestone
from anumaan.turn import bearing, classify_turn, turn_angle

from .maps import AREAS_DIR

_CLEMSON_SLUG = "area-34-685-82-836-3000m"

# Fallback speed limits (m/s) by OSM highway class when maxspeed is missing.
_DEFAULT_SPEEDS = {
    "motorway": 31.0, "trunk": 27.0, "primary": 18.0, "secondary": 15.0,
    "tertiary": 13.0, "residential": 11.0, "living_street": 7.0,
    "service": 7.0, "unclassified": 11.0,
}
_FALLBACK_SPEED = 11.0


@lru_cache(maxsize=8)
def load_graph(slug: str) -> nx.MultiDiGraph:
    path = AREAS_DIR / slug / "graph.graphml"
    if not path.exists():
        raise FileNotFoundError(f"no downloaded graph for area {slug!r}")
    return ox.load_graphml(path)


def _haversine(lat1, lon1, lat2, lon2) -> float:
    R = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dlat, dlon = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    h = math.sin(dlat / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlon / 2) ** 2
    return 2 * R * math.asin(min(1.0, math.sqrt(h)))


def nearest_node(graph: nx.MultiDiGraph, lat: float, lon: float) -> int:
    """Nearest graph node to a lat/lon by great-circle distance.

    A plain scan (no scikit-learn / projection needed) — fine for the
    personal-scale areas this app downloads.
    """
    best, best_d = None, float("inf")
    for node, data in graph.nodes(data=True):
        d = _haversine(lat, lon, float(data["y"]), float(data["x"]))
        if d < best_d:
            best, best_d = node, d
    if best is None:
        raise ValueError("graph has no nodes")
    return int(best)


def _first_scalar(value):
    return value[0] if isinstance(value, (list, tuple)) and value else value


def _parse_speed(maxspeed, highway) -> float:
    ms = _first_scalar(maxspeed)
    if ms is not None:
        m = re.search(r"\d+(?:\.\d+)?", str(ms))
        if m:
            val = float(m.group())
            return val * 0.44704 if "mph" in str(ms).lower() else val / 3.6
    hw = _first_scalar(highway)
    return _DEFAULT_SPEEDS.get(str(hw), _FALLBACK_SPEED)


def _node_type(graph: nx.MultiDiGraph, node: int) -> str:
    data = graph.nodes[node]
    hw = str(_first_scalar(data.get("highway", "")) or "")
    if "stop" in hw:
        return "stop_sign"
    if "traffic_signals" in hw or "signal" in hw:
        return "traffic_light"
    if "crossing" in hw:
        return "crossing"
    if "mini_roundabout" in hw or "roundabout" in hw:
        return "roundabout"
    return "intersection"


def _best_edge(graph: nx.MultiDiGraph, u: int, v: int) -> dict:
    """Pick the shortest parallel edge between u and v (MultiDiGraph)."""
    edges = graph.get_edge_data(u, v) or graph.get_edge_data(v, u) or {}
    if not edges:
        return {}
    return min(edges.values(), key=lambda d: d.get("length", float("inf")))


def _edge_coords(graph, u, v, edge) -> list[list[float]]:
    """Return [[lat, lon], …] for an edge, following its real geometry."""
    geom = edge.get("geometry")
    if geom is not None and hasattr(geom, "coords"):
        # shapely LineString in (lon, lat) order.
        coords = [[float(y), float(x)] for x, y in geom.coords]
        return coords
    a, b = graph.nodes[u], graph.nodes[v]
    return [[float(a["y"]), float(a["x"])], [float(b["y"]), float(b["x"])]]


def compute_route(slug: str, start: tuple[float, float],
                  dest: tuple[float, float]) -> dict:
    """Compute a route between two lat/lon points on the area's road graph."""
    graph = load_graph(slug)
    orig = nearest_node(graph, *start)
    target = nearest_node(graph, *dest)
    if orig == target:
        raise ValueError("start and destination snap to the same road node; "
                         "pick points further apart")
    try:
        path = nx.shortest_path(graph, orig, target, weight="length")
    except nx.NetworkXNoPath as exc:
        raise ValueError("no drivable route between those points") from exc

    coords: list[list[float]] = []
    milestones: list[Milestone] = []
    nodes_meta: list[dict] = []
    total = 0.0

    # Origin milestone (distance 0).
    o = graph.nodes[orig]
    milestones.append(Milestone(id=str(orig), type=_node_type(graph, orig),
                                distance_from_prior=0.0,
                                name="Start", target_speed_limit=_FALLBACK_SPEED))
    nodes_meta.append({"id": str(orig), "lat": float(o["y"]), "lon": float(o["x"]),
                       "type": _node_type(graph, orig), "name": "Start",
                       "cumulative_m": 0.0, "leg_bearing": 0.0, "leg_straight": False})
    coords.append([float(o["y"]), float(o["x"])])

    for u, v in zip(path[:-1], path[1:]):
        edge = _best_edge(graph, u, v)
        length = float(edge.get("length", 0.0))
        total += length
        speed = _parse_speed(edge.get("maxspeed"), edge.get("highway"))
        street = _first_scalar(edge.get("name")) or "unnamed road"

        seg = _edge_coords(graph, u, v, edge)
        coords.extend(seg[1:] if coords and seg and coords[-1] == seg[0] else seg)

        is_last = v == path[-1]
        ud, vd = graph.nodes[u], graph.nodes[v]
        ntype = _node_type(graph, v)
        label = "Destination" if is_last else str(street)
        # Leg geometry for calibration: the node-to-node compass bearing, and a
        # "straight" flag from sinuosity (edge length vs. straight-line distance).
        leg_bear = bearing((float(ud["y"]), float(ud["x"])),
                           (float(vd["y"]), float(vd["x"])))
        straight_dist = _haversine(float(ud["y"]), float(ud["x"]),
                                   float(vd["y"]), float(vd["x"]))
        straight = straight_dist >= 40.0 and length <= 1.08 * max(straight_dist, 1e-6)
        milestones.append(Milestone(id=str(v), type="destination" if is_last else ntype,
                                    distance_from_prior=length, name=label,
                                    target_speed_limit=speed))
        nodes_meta.append({"id": str(v), "lat": float(vd["y"]), "lon": float(vd["x"]),
                           "type": ntype, "name": label, "cumulative_m": total,
                           "leg_bearing": round(leg_bear, 1), "leg_straight": straight})

    # Expected turn (from geometry) at each intermediate node.
    for i in range(len(nodes_meta)):
        if 0 < i < len(nodes_meta) - 1:
            a = (nodes_meta[i - 1]["lat"], nodes_meta[i - 1]["lon"])
            n = (nodes_meta[i]["lat"], nodes_meta[i]["lon"])
            b = (nodes_meta[i + 1]["lat"], nodes_meta[i + 1]["lon"])
            ang = turn_angle(a, n, b)
            nodes_meta[i]["turn_angle"] = round(ang, 1)
            nodes_meta[i]["turn_label"] = classify_turn(ang)
        else:
            nodes_meta[i]["turn_angle"] = 0.0
            nodes_meta[i]["turn_label"] = "start" if i == 0 else "arrive"

    avg_speed = sum(m.target_speed_limit for m in milestones[1:]) / max(len(milestones) - 1, 1)
    return {
        "slug": slug,
        "coords": coords,
        "milestones": [
            {"id": m.id, "type": m.type, "name": m.name,
             "distance_from_prior": m.distance_from_prior,
             "target_speed_limit": m.target_speed_limit}
            for m in milestones
        ],
        "nodes": nodes_meta,
        "total_distance_m": total,
        "est_time_s": total / max(avg_speed, 1.0),
        "_milestone_objs": milestones,  # kept for the nav session (not serialized to client)
    }


def graph_node_bounds(graph: nx.MultiDiGraph) -> tuple[float, float, float, float]:
    """(south, west, north, east) spanned by the graph's nodes."""
    ys = [float(d["y"]) for _, d in graph.nodes(data=True)]
    xs = [float(d["x"]) for _, d in graph.nodes(data=True)]
    return min(ys), min(xs), max(ys), max(xs)


def graph_matches_bbox(graph: nx.MultiDiGraph, info: dict, tol_deg: float = 0.02) -> bool:
    """True if the graph's road nodes are contained in the area's rectangle.

    osmnx clips a fresh download to the requested bbox, so a correct graph's
    node bounds always sit inside the rectangle. A graph whose nodes spill
    outside it is therefore stale — left from a previous download of the same
    area id at a different location (the red rectangle moved but the cached
    roads didn't, so walks render outside the box). The tolerance absorbs the
    odd boundary-crossing node osmnx retains.
    """
    if graph.number_of_nodes() == 0:
        return False
    gs, gw, gn, ge = graph_node_bounds(graph)
    return (gs >= info["south"] - tol_deg and gn <= info["north"] + tol_deg
            and gw >= info["west"] - tol_deg and ge <= info["east"] + tol_deg)


def download_area_graph(info: dict) -> nx.MultiDiGraph:
    """Fresh osmnx download for an area's bbox. osmnx 2.x wants (W, S, E, N)."""
    return ox.graph_from_bbox(
        (info["west"], info["south"], info["east"], info["north"]),
        network_type="drive",
    )


def resolve_area_graph(area_id: str, *, force_refresh: bool = False) -> nx.MultiDiGraph:
    """Return a loaded networkx graph for a sim area, downloading and caching if needed.

    Resolution order:
    1. Cached sim-specific graphml — but only if its roads still fall inside the
       area's current rectangle (else it's stale and gets re-downloaded).
    2. Existing Clemson nav graph (geographic match, avoids re-download).
    3. osmnx download from the area's bbox, then cache.

    force_refresh skips the cache entirely (used right after a (re)download so
    the cache can never lag behind the stored bbox).
    """
    # Lazy import to avoid circular dependency (sim imports routing, routing imports sim here).
    from .sim import AREAS  # noqa: PLC0415
    info = AREAS.get(area_id)
    cached_path = AREAS_DIR / f"sim-{area_id}" / "graph.graphml"

    if cached_path.exists() and not force_refresh:
        graph = ox.load_graphml(cached_path)
        if info is None or graph_matches_bbox(graph, info):
            return graph
        print(f"[sim] cached graph for {area_id!r} sits outside its rectangle — refreshing")

    if area_id == "clemson":
        return load_graph(_CLEMSON_SLUG)

    if info is None:
        raise ValueError(f"Unknown sim area: {area_id!r}")

    graph = download_area_graph(info)
    cached_path.parent.mkdir(parents=True, exist_ok=True)
    ox.save_graphml(graph, cached_path)
    return graph


def _node_ll(graph: nx.MultiDiGraph, node: int) -> tuple[float, float]:
    d = graph.nodes[node]
    return float(d["y"]), float(d["x"])


def _walk_coverage(
    graph: nx.MultiDiGraph,
    node_seq: list[int],
    edge_seq: list[frozenset],
    distance_m: float,
) -> dict:
    """Geometry-quality metrics for a walk: how much *new* ground it covers.

    - edge_revisit_ratio / node_revisit_ratio: fraction of steps that re-tread
      an edge / node already visited (0 = never repeats, higher = loops back).
    - straightness: net displacement / path length (1 = straight line, ~0 = loop
      that returns near its start).
    - coverage_bbox_m2: bounding-box area spanned, a rough spread proxy.
    """
    n_edges = len(edge_seq)
    edge_revisit = round(1 - len(set(edge_seq)) / n_edges, 3) if n_edges else 0.0
    node_revisit = round(1 - len(set(node_seq)) / len(node_seq), 3) if node_seq else 0.0

    lat0, lon0 = _node_ll(graph, node_seq[0])
    lat1, lon1 = _node_ll(graph, node_seq[-1])
    net = _haversine(lat0, lon0, lat1, lon1)
    straightness = round(net / distance_m, 3) if distance_m else 0.0

    lls = [_node_ll(graph, n) for n in node_seq]
    lats = [p[0] for p in lls]
    lons = [p[1] for p in lls]
    h = _haversine(min(lats), min(lons), max(lats), min(lons))  # N-S extent
    w = _haversine(min(lats), min(lons), min(lats), max(lons))  # E-W extent
    bbox_area = round(h * w, 1)

    # Geometric turn count (proxy for Swift's significant turns, available at
    # generation time so we can filter out bland straight trails before benchmarking).
    geo_turns = 0
    for i in range(1, len(lls) - 1):
        if abs(turn_angle(lls[i - 1], lls[i], lls[i + 1])) >= 30.0:
            geo_turns += 1

    return {
        "edge_revisit_ratio": edge_revisit,
        "node_revisit_ratio": node_revisit,
        "straightness": straightness,
        "coverage_bbox_m2": bbox_area,
        "geo_turns": geo_turns,
    }


def _build_walk(
    graph: nx.MultiDiGraph,
    start: int,
    min_distance_m: float,
    rng: random.Random,
    *,
    self_avoiding: bool = False,
) -> dict | None:
    """Walk from start until min_distance_m is reached; return None if it dead-ends short.

    When ``self_avoiding`` is set, strongly prefer edges/nodes not yet visited so the
    walk covers new ground instead of looping over the same streets — only falling
    back to a revisit when genuinely boxed in. The default mode merely avoids the
    immediate U-turn, which on suburban loops still produces lots of doubling back.
    """
    n0 = graph.nodes[start]
    coords: list[list[float]] = [[float(n0["y"]), float(n0["x"])]]
    distance = 0.0
    prev: int | None = None
    cur = start

    node_seq: list[int] = [start]
    edge_seq: list[frozenset] = []
    visited_edges: set[frozenset] = set()
    visited_nodes: set[int] = {start}

    for _ in range(400):
        neighbors = [n for n in graph.successors(cur) if n != prev]
        if not neighbors:
            if prev is not None:
                neighbors = [prev]  # dead-end: allow U-turn as last resort
            else:
                break

        if self_avoiding:
            # Prefer edges to brand-new nodes; then unvisited edges; then anything.
            pool = [n for n in neighbors
                    if frozenset((cur, n)) not in visited_edges and n not in visited_nodes]
            if not pool:
                pool = [n for n in neighbors if frozenset((cur, n)) not in visited_edges]
            if not pool:
                pool = neighbors
        else:
            pool = neighbors

        nxt = rng.choice(pool)
        edge = _best_edge(graph, cur, nxt)
        if not edge:
            break

        distance += float(edge.get("length", 0.0))
        seg = _edge_coords(graph, cur, nxt, edge)
        coords.extend(seg[1:] if coords and seg and coords[-1] == seg[0] else seg)

        e = frozenset((cur, nxt))
        edge_seq.append(e)
        visited_edges.add(e)
        node_seq.append(nxt)
        visited_nodes.add(nxt)

        prev, cur = cur, nxt
        if distance >= min_distance_m:
            break

    if distance >= min_distance_m and len(coords) >= 2:
        metrics = _walk_coverage(graph, node_seq, edge_seq, distance)
        return {"start_node": start, "coords": coords, "distance_m": distance,
                "_sig": frozenset(edge_seq), **metrics}
    return None


def _single_trail(
    graph: nx.MultiDiGraph,
    start: int,
    min_distance_m: float,
    rng: random.Random,
) -> dict | None:
    """One edge-disjoint trail attempt: never re-walk a street segment.

    A *trail* (graph theory) is a walk with no repeated edge — so edge_revisit
    is 0 by construction. To run far before stranding itself, it uses a
    dead-end-deferral look-ahead: among the unused streets out of the current
    node, prefer ones that still have an onward unused street, so we don't step
    into a one-way pocket a move too early. Stops when no unused street remains.
    """
    n0 = graph.nodes[start]
    coords: list[list[float]] = [[float(n0["y"]), float(n0["x"])]]
    distance = 0.0
    prev: int | None = None
    cur = start
    used: set[frozenset] = set()
    node_seq: list[int] = [start]
    edge_seq: list[frozenset] = []

    for _ in range(600):
        fresh = [n for n in graph.successors(cur) if frozenset((cur, n)) not in used]
        non_uturn = [n for n in fresh if n != prev]
        fresh = non_uturn or fresh  # only U-turn if it's the sole unused street
        if not fresh:
            break  # no unused street out of here → the trail ends

        def onward(n: int) -> int:
            return sum(1 for m in graph.successors(n)
                       if m != cur and frozenset((n, m)) not in used)

        alive = [n for n in fresh if onward(n) > 0]
        nxt = rng.choice(alive or fresh)

        edge = _best_edge(graph, cur, nxt)
        if not edge:
            break
        distance += float(edge.get("length", 0.0))
        seg = _edge_coords(graph, cur, nxt, edge)
        coords.extend(seg[1:] if coords and seg and coords[-1] == seg[0] else seg)

        e = frozenset((cur, nxt))
        used.add(e)
        edge_seq.append(e)
        node_seq.append(nxt)
        prev, cur = cur, nxt
        if distance >= min_distance_m:
            break

    if len(coords) >= 2:
        metrics = _walk_coverage(graph, node_seq, edge_seq, distance)
        return {"start_node": start, "coords": coords, "distance_m": distance,
                "_sig": frozenset(edge_seq), **metrics}
    return None


def _build_trail(
    graph: nx.MultiDiGraph,
    start: int,
    min_distance_m: float,
    rng: random.Random,
    *,
    max_attempts: int = 14,
) -> dict | None:
    """Retry edge-disjoint trails from ``start`` until one reaches the distance
    target. Returns None if every attempt dead-ends short (caller skips it)."""
    for _ in range(max_attempts):
        walk = _single_trail(graph, start, min_distance_m, rng)
        if walk and walk["distance_m"] >= min_distance_m:
            return walk
    return None


def generate_random_walks(
    graph_or_slug: nx.MultiDiGraph | str,
    num_starts: int,
    walks_per_start: int,
    min_distance_m: float,
    *,
    seed: int | None = None,
    walk_style: str = "default",
    dedupe: bool = True,
    min_turns: int = 0,
) -> list[dict]:
    """Generate random road walks of at least min_distance_m.

    Returns a list of dicts with keys: start_node, coords ([[lat,lon],...]),
    distance_m, plus coverage metrics from ``_walk_coverage``.
    Reproducible when seed is given.

    walk_style:
      - "default":       random, only avoids the immediate U-turn (loops a lot)
      - "self_avoiding": greedily prefers unused streets, falls back to reuse
      - "strict_trail":  never reuses a street (0% edge revisit), with retries

    dedupe: skip a walk whose exact edge set was already produced (a start with
      few route choices otherwise re-walks the same trail, wasting the budget).
    min_turns: reject walks with fewer than this many geometric turns (≥30°) —
      filters out bland straight runs that alias to every other straight road.
    """
    graph = load_graph(graph_or_slug) if isinstance(graph_or_slug, str) else graph_or_slug
    rng = random.Random(seed)

    all_nodes = list(graph.nodes())
    if not all_nodes:
        return []
    good_starts = [n for n in all_nodes if graph.degree(n) >= 2] or all_nodes

    def build_one(start: int) -> dict | None:
        if walk_style == "strict_trail":
            return _build_trail(graph, start, min_distance_m, rng)
        return _build_walk(graph, start, min_distance_m, rng,
                           self_avoiding=(walk_style == "self_avoiding"))

    # When filtering/deduping, give each slot several tries to find a fresh,
    # turny route from its start before giving up on that slot.
    attempts = 12 if (dedupe or min_turns > 0) else 1

    seen: set[frozenset] = set()
    walks: list[dict] = []
    for _ in range(num_starts):
        start = rng.choice(good_starts)
        for _ in range(walks_per_start):
            chosen: dict | None = None
            for _ in range(attempts):
                cand = build_one(start)
                if not cand:
                    break
                sig = cand.get("_sig")
                if dedupe and sig is not None and sig in seen:
                    continue
                if min_turns > 0 and (cand.get("geo_turns") or 0) < min_turns:
                    continue
                chosen = cand
                break
            if chosen is not None:
                sig = chosen.pop("_sig", None)
                if sig is not None:
                    seen.add(sig)
                walks.append(chosen)
    return walks
