"""Simulation endpoint: calls the AnumaanSim CLI and returns JSON.

The Swift binary does all the real work — road graph building, elevation
matching, recovery-session interrogation. This module is purely glue.
"""

from __future__ import annotations

import json
import os
import random
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from fastapi import HTTPException
from pydantic import BaseModel, Field

_PACKAGE_DIR = Path(__file__).resolve().parent.parent / "ios" / "AnumaanCore"
# Prefer the optimized release binary — off-trail curve matching (DTW over a
# 15k-candidate grid) is ~20-50x faster compiled than in the debug build.
# Rebuild with: swift build -c release --product AnumaanSim
_RELEASE_BINARY = _PACKAGE_DIR / ".build" / "release" / "AnumaanSim"
_DEBUG_BINARY = _PACKAGE_DIR / ".build" / "debug" / "AnumaanSim"
_BINARY = _RELEASE_BINARY if _RELEASE_BINARY.exists() else _DEBUG_BINARY

AREAS_FILE = Path(__file__).resolve().parent.parent / "data" / "sim_areas.json"

DEFAULT_AREAS = {
    "clemson": {
        "south": 34.669, "west": -82.849,
        "north": 34.691, "east": -82.823,
        "center": [34.680, -82.836],
        "zoom": 14,
        "name": "Clemson, SC"
    },
}

def load_areas() -> dict[str, dict]:
    try:
        if AREAS_FILE.exists():
            return json.loads(AREAS_FILE.read_text())
    except Exception as e:
        print(f"Error loading sim_areas.json: {e}")
    try:
        AREAS_FILE.parent.mkdir(parents=True, exist_ok=True)
        AREAS_FILE.write_text(json.dumps(DEFAULT_AREAS, indent=2))
    except Exception as e:
        print(f"Error saving default sim_areas.json: {e}")
    return dict(DEFAULT_AREAS)

AREAS: dict[str, dict] = load_areas()

def save_areas() -> None:
    try:
        AREAS_FILE.parent.mkdir(parents=True, exist_ok=True)
        AREAS_FILE.write_text(json.dumps(AREAS, indent=2))
    except Exception as e:
        print(f"Error saving sim_areas.json: {e}")


# ---- request / response models --------------------------------------------

class SimRequest(BaseModel):
    area: str = "clemson"
    path: list[list[float]]
    mode: str = "road"


class BenchmarkRequest(BaseModel):
    area: str
    num_starts: int = Field(default=5, ge=1, le=20)
    walks_per_start: int = Field(default=4, ge=1, le=10)
    min_distance_m: float = Field(default=2000.0, ge=200.0, le=5000.0)
    mode: str = "road"
    seed: int | None = None
    randomize_min_questions: bool = False
    walk_style: str = "default"  # default | self_avoiding | strict_trail
    self_avoiding: bool = False  # legacy flag → maps to walk_style="self_avoiding"
    min_turns: int = Field(default=0, ge=0, le=20)  # reject walks with fewer turns (0 = off)
    placements_per_shape: int = Field(default=8, ge=1, le=80)  # off-trail: walks per shape
    shapes: list[str] | None = None  # off-trail: which shapes to test (None = all)
    zigzag_angle_deg: float = Field(default=30.0, ge=5.0, le=85.0)  # zigzag leg angle off travel line


# ---- Swift invocation helpers ---------------------------------------------

def _invoke_sim(
    area: str,
    path: list[list[float]],
    mode: str,
    area_info: dict,
    extra_flags: list[str],
) -> str:
    """Call AnumaanSim with the given path and flags; return raw stdout.

    Raises HTTPException on binary-not-found or non-zero exit.
    """
    if not _BINARY.exists():
        raise HTTPException(503, (
            f"AnumaanSim binary not found at {_BINARY}. "
            "Build it first:\n"
            "  cd ios/AnumaanCore\n"
            "  GIT_CONFIG_PARAMETERS=\"'safe.bareRepository=all'\" "
            "  swift build --product AnumaanSim"
        ))

    path_json = json.dumps(path)
    bbox_str = (
        f"{area_info['south']},{area_info['west']}"
        f",{area_info['north']},{area_info['east']}"
    )
    cmd = [str(_BINARY), area, "--path", path_json, "--mode", mode,
           "--bbox", bbox_str, *extra_flags]

    result = subprocess.run(
        cmd,
        capture_output=True, text=True, timeout=120,
        env={**os.environ, "GIT_CONFIG_PARAMETERS": "'safe.bareRepository=all'"},
    )
    stderr = result.stderr.strip()
    if stderr:
        print(f"--- AnumaanSim stderr ---\n{stderr}\n-------------------------")
    if result.returncode != 0 or not result.stdout.strip():
        raise HTTPException(500, f"Simulation failed: {stderr or 'no output'}")
    return result.stdout.strip()


# ---- single-walk endpoint -------------------------------------------------

def run_sim(req: SimRequest) -> dict:
    if req.area not in AREAS:
        raise HTTPException(400, f"Unknown area '{req.area}'. Known: {list(AREAS)}")
    if len(req.path) < 2:
        raise HTTPException(400, "path must have at least 2 points")

    stdout = _invoke_sim(req.area, req.path, req.mode, AREAS[req.area], ["--json"])

    try:
        data = json.loads(stdout)
    except json.JSONDecodeError as e:
        raise HTTPException(500, f"Bad JSON from sim: {e}\nOutput: {stdout[:400]}")

    if "error" in data:
        raise HTTPException(400, data["error"])

    data["areaInfo"] = AREAS[req.area]

    try:
        data_dir = Path(__file__).resolve().parent.parent / "data"
        data_dir.mkdir(parents=True, exist_ok=True)
        sim_payload = {
            "req": {"area": req.area, "path": req.path, "mode": req.mode},
            "res": data,
        }
        (data_dir / "last_simulation.json").write_text(json.dumps(sim_payload, indent=2))
    except Exception as e:
        print(f"Error saving last_simulation.json: {e}")

    return data


# ---- batch benchmark worker -----------------------------------------------

def run_benchmark(job: dict, req: BenchmarkRequest) -> None:
    """Background worker: generate walks, run them in parallel, aggregate results.

    Updates `job` dict in-place so the polling endpoint can report progress.
    """
    try:
        if req.area not in AREAS:
            job["error"] = f"Unknown area '{req.area}'"
            job["done"] = True
            return

        area_info = AREAS[req.area]

        # Off-trail (wilderness) benchmark is a separate pipeline: terrain shape
        # walks over the DEM instead of road walks over the graph.
        if req.mode == "offtrail":
            _run_offtrail_benchmark(job, req, area_info)
            return

        # Phase 1: resolve road graph (may trigger osmnx download for new areas)
        job["message"] = "Resolving road graph…"
        from . import routing  # noqa: PLC0415
        try:
            graph = routing.resolve_area_graph(req.area)
        except Exception as exc:
            job["error"] = f"Could not load graph for '{req.area}': {exc}"
            job["done"] = True
            return

        # Phase 2: generate random walks
        job["message"] = "Generating random walks…"
        style = req.walk_style
        if style == "default" and req.self_avoiding:  # legacy callers
            style = "self_avoiding"
        walks_raw = routing.generate_random_walks(
            graph,
            req.num_starts,
            req.walks_per_start,
            req.min_distance_m,
            seed=req.seed,
            walk_style=style,
            dedupe=True,
            min_turns=req.min_turns,
        )
        if not walks_raw:
            job["error"] = "Could not generate any walks; try lowering min distance or increasing start points"
            job["done"] = True
            return

        total = len(walks_raw)
        job["message"] = f"Running {total} walks through Swift…"

        # Assign min_questions per walk (random 1-4, or fixed at 1)
        rng_mq = random.Random(req.seed)
        min_q_assignments = [
            rng_mq.randint(1, 4) if req.randomize_min_questions else 1
            for _ in walks_raw
        ]

        # Phase 3: run walks through Swift in parallel (max 4 workers)
        walk_results: list[dict] = []
        completed = 0

        def _run_one(i: int, walk: dict, min_q: int) -> dict:
            base: dict = {
                "id": i,
                "distance_m": walk["distance_m"],
                "coords": walk["coords"],
                "success": False,
                "located_error_m": None,
                "located_conc": 0.0,
                "located_lat": None,
                "located_lon": None,
                "true_end_lat": None,
                "true_end_lon": None,
                "q_answered_count": 0,
                "significant_turns": 0,
                "min_questions": min_q,
                # Coverage metrics (from the walk generator, not Swift)
                "edge_revisit_ratio": walk.get("edge_revisit_ratio"),
                "node_revisit_ratio": walk.get("node_revisit_ratio"),
                "straightness": walk.get("straightness"),
                "coverage_bbox_m2": walk.get("coverage_bbox_m2"),
                "geo_turns": walk.get("geo_turns"),
            }
            try:
                flags = ["--benchmark", "--min-questions", str(min_q)]
                stdout = _invoke_sim(
                    req.area, walk["coords"], req.mode, area_info, flags
                )
                raw = json.loads(stdout)
                if "error" in raw:
                    return {**base, "error": raw["error"]}
                error_m = raw.get("locatedErrorM")
                conc = float(raw.get("locatedConc", 0.0))
                success = (
                    raw.get("located", False)
                    and error_m is not None
                    and error_m < 120
                    and conc >= 0.80
                )
                return {
                    **base,
                    "success": success,
                    "located_error_m": error_m,
                    "located_conc": conc,
                    "located_lat": raw.get("locatedLat"),
                    "located_lon": raw.get("locatedLon"),
                    "true_end_lat": raw.get("trueEndLat"),
                    "true_end_lon": raw.get("trueEndLon"),
                    "q_answered_count": int(raw.get("qAnsweredCount", 0)),
                    "significant_turns": int(raw.get("significantTurns", 0)),
                    "heading_std_dev": float(raw.get("headingStdDev", 0.0)),
                    "total_heading_change_deg": float(raw.get("totalHeadingChangeDeg", 0.0)),
                    "elev_gain_m": float(raw.get("elevGainM", 0.0)),
                    "elev_range_m": float(raw.get("elevRangeM", 0.0)),
                    "min_questions": int(raw.get("minQuestionsUsed", min_q)),
                }
            except Exception as exc:
                return {**base, "error": str(exc)}

        with ThreadPoolExecutor(max_workers=4) as pool:
            futures = {
                pool.submit(_run_one, i, w, min_q_assignments[i]): i
                for i, w in enumerate(walks_raw)
            }
            for future in as_completed(futures):
                walk_results.append(future.result())
                completed += 1
                job["frac"] = round(completed / total, 3)
                job["message"] = f"Completed {completed}/{total} walks…"

        walk_results.sort(key=lambda w: w["id"])

        # Phase 4: aggregate
        located = [w for w in walk_results if w["success"]]
        located_count = len(located)
        total_count = len(walk_results)

        def _avg(values: list[float | None]) -> float | None:
            clean = [v for v in values if v is not None]
            return round(sum(clean) / len(clean), 2) if clean else None

        job["result"] = {
            "uniqueness_score": round(located_count / total_count, 4) if total_count else 0.0,
            "avg_turns_to_localize": _avg([w["significant_turns"] for w in located]),
            "avg_questions_to_localize": _avg([w["q_answered_count"] for w in located]),
            "avg_error_m": _avg([w["located_error_m"] for w in located]),
            "total_walks": total_count,
            "located_count": located_count,
            "areaInfo": area_info,
            "walks": walk_results,
        }

        # Persist to disk (coords stripped to keep file manageable).
        try:
            data_dir = Path(__file__).resolve().parent.parent / "data"
            data_dir.mkdir(parents=True, exist_ok=True)
            saved = {
                **job["result"],
                "area": req.area,
                "params": {
                    "num_starts": req.num_starts,
                    "walks_per_start": req.walks_per_start,
                    "min_distance_m": req.min_distance_m,
                    "mode": req.mode,
                    "seed": req.seed,
                    "randomize_min_questions": req.randomize_min_questions,
                    "walk_style": style,
                    "dedupe": True,
                    "min_turns": req.min_turns,
                },
                "walks": [
                    {k: v for k, v in w.items() if k != "coords"}
                    for w in walk_results
                ],
            }
            (data_dir / "last_benchmark.json").write_text(json.dumps(saved, indent=2))
        except Exception as exc:
            print(f"Error saving last_benchmark.json: {exc}")

        job["message"] = "Done"
        job["done"] = True

    except Exception as exc:
        job["error"] = str(exc)
        job["done"] = True


# ---- off-trail (wilderness) benchmark worker ------------------------------

_OFFTRAIL_SUCCESS_M = 120.0  # located within this many metres counts as a hit


def _run_offtrail_benchmark(job: dict, req: BenchmarkRequest, area_info: dict) -> None:
    """Lay each shape on the area's terrain, run them through the off-trail
    engine, and report which shape localizes best plus what distinguishes the
    walks that localize from those that don't."""
    from . import terrain  # noqa: PLC0415

    job["message"] = "Loading terrain (DEM)…"
    try:
        dem = terrain.load_dem(req.area)
    except Exception as exc:
        job["error"] = (
            f"No terrain data for '{req.area}'. Download the area first so its "
            f"elevation tiles get cached. ({exc})"
        )
        job["done"] = True
        return

    shapes = req.shapes or terrain.SHAPE_TYPES
    shapes = [s for s in shapes if s in terrain.SHAPE_TYPES]
    if not shapes:
        job["error"] = f"No valid shapes selected. Choose from: {terrain.SHAPE_TYPES}"
        job["done"] = True
        return

    job["message"] = "Generating shape walks…"
    walks_raw = terrain.generate_shape_walks(
        dem,
        area_info["south"], area_info["west"], area_info["north"], area_info["east"],
        shapes=shapes,
        target_len_m=req.min_distance_m,
        placements=req.placements_per_shape,
        seed=req.seed,
        zigzag_angle_deg=req.zigzag_angle_deg,
    )
    if not walks_raw:
        job["error"] = "Could not place any shapes — the walk length may be too large for this area."
        job["done"] = True
        return

    total = len(walks_raw)
    job["message"] = f"Running {total} off-trail walks…"
    _GEN_KEYS = ("shape", "distance_m", "elev_gain_m", "elev_range_m", "net_elev_m",
                 "elev_roughness_m_per_km", "monotonicity", "early_gain_frac",
                 "mid_gain_frac", "late_gain_frac", "straightness", "curvature_per_km")

    def _run_one(i: int, walk: dict) -> dict:
        base = {k: walk.get(k) for k in _GEN_KEYS}
        base.update({"id": i, "coords": walk["coords"], "success": False,
                     "located_error_m": None, "located_lat": None, "located_lon": None,
                     "true_end_lat": None, "true_end_lon": None})
        try:
            raw = json.loads(_invoke_sim(req.area, walk["coords"], "offtrail",
                                         area_info, ["--benchmark"]))
            if "error" in raw:
                return {**base, "error": raw["error"]}
            err = raw.get("locatedErrorM")
            return {
                **base,
                "success": bool(raw.get("located")) and err is not None and err < _OFFTRAIL_SUCCESS_M,
                "located_error_m": err,
                "located_conc": float(raw.get("locatedConc", 0.0)),
                "located_lat": raw.get("locatedLat"),
                "located_lon": raw.get("locatedLon"),
                "true_end_lat": raw.get("trueEndLat"),
                "true_end_lon": raw.get("trueEndLon"),
            }
        except Exception as exc:
            return {**base, "error": str(exc)}

    walk_results: list[dict] = []
    completed = 0
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(_run_one, i, w) for i, w in enumerate(walks_raw)]
        for fut in as_completed(futures):
            walk_results.append(fut.result())
            completed += 1
            job["frac"] = round(completed / total, 3)
            job["message"] = f"Completed {completed}/{total} off-trail walks…"
    walk_results.sort(key=lambda w: w["id"])

    # Per-shape leaderboard
    import statistics  # noqa: PLC0415
    by_shape: dict[str, list[dict]] = {}
    for w in walk_results:
        by_shape.setdefault(w.get("shape", "?"), []).append(w)

    shapes: list[dict] = []
    for shape, group in by_shape.items():
        errs = [w["located_error_m"] for w in group if w["located_error_m"] is not None]
        loc = sum(1 for w in group if w["success"])
        shapes.append({
            "shape": shape,
            "located": loc,
            "total": len(group),
            "rate": round(loc / len(group), 3) if group else 0.0,
            "median_error_m": round(statistics.median(errs), 1) if errs else None,
            "curvature_per_km": round(statistics.mean(w["curvature_per_km"] for w in group), 1),
            "elev_gain_m": round(statistics.mean(w["elev_gain_m"] for w in group), 1),
        })
    shapes.sort(key=lambda s: (s["rate"], -(s["median_error_m"] or 9e9)), reverse=True)

    # What localizes? located-vs-not feature comparison
    located = [w for w in walk_results if w["success"]]
    notloc = [w for w in walk_results if not w["success"]]
    feat_keys = ["early_gain_frac", "mid_gain_frac", "late_gain_frac",
                 "elev_roughness_m_per_km", "curvature_per_km", "elev_gain_m", "elev_range_m"]

    def _mean(rows, k):
        vals = [r[k] for r in rows if r.get(k) is not None]
        return round(sum(vals) / len(vals), 2) if vals else None

    feature_compare = {k: {"located": _mean(located, k), "not": _mean(notloc, k)}
                       for k in feat_keys}

    total_count = len(walk_results)
    job["result"] = {
        "mode": "offtrail",
        "uniqueness_score": round(len(located) / total_count, 4) if total_count else 0.0,
        "located_count": len(located),
        "total_walks": total_count,
        "avg_error_m": _mean(located, "located_error_m"),
        "shapes": shapes,
        "feature_compare": feature_compare,
        "areaInfo": area_info,
        "walks": walk_results,
    }

    try:
        data_dir = Path(__file__).resolve().parent.parent / "data"
        data_dir.mkdir(parents=True, exist_ok=True)
        saved = {
            **job["result"],
            "area": req.area,
            "params": {"mode": "offtrail", "min_distance_m": req.min_distance_m,
                       "placements_per_shape": req.placements_per_shape,
                       "shapes": shapes, "zigzag_angle_deg": req.zigzag_angle_deg,
                       "seed": req.seed},
            "walks": [{k: v for k, v in w.items() if k != "coords"} for w in walk_results],
        }
        (data_dir / "last_benchmark.json").write_text(json.dumps(saved, indent=2))
    except Exception as exc:
        print(f"Error saving last_benchmark.json: {exc}")

    job["message"] = "Done"
    job["done"] = True
