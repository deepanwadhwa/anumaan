"""Routing over a downloaded OSM road graph, and conversion to milestones.

Snaps two clicked points to the nearest road-network nodes, finds the
shortest path with networkx, and turns that path into:

  * a dense ``coords`` polyline (following real road geometry) for drawing, and
  * a ``Milestone`` array (one per graph node on the path) for the Anumaan engine.
"""

from __future__ import annotations

import math
import re
from functools import lru_cache

import networkx as nx
import osmnx as ox

from anumaan.models import Milestone
from anumaan.turn import bearing, classify_turn, turn_angle

from .maps import AREAS_DIR

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
