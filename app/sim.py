"""Simulation endpoint: calls the AnumaanSim CLI and returns JSON.

The Swift binary does all the real work — road graph building, elevation
matching, recovery-session interrogation. This module is purely glue.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

from fastapi import HTTPException
from pydantic import BaseModel

_PACKAGE_DIR = Path(__file__).resolve().parent.parent / "ios" / "AnumaanCore"
_BINARY = _PACKAGE_DIR / ".build" / "debug" / "AnumaanSim"

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



class SimRequest(BaseModel):
    area: str = "clemson"
    # User draws a path as an ordered list of [lat, lon] waypoints.
    # Must have at least 2 points and cover enough distance to localise.
    path: list[list[float]]
    mode: str = "road"


def run_sim(req: SimRequest) -> dict:
    if req.area not in AREAS:
        raise HTTPException(400, f"Unknown area '{req.area}'. Known: {list(AREAS)}")
    if len(req.path) < 2:
        raise HTTPException(400, "path must have at least 2 points")
    if not _BINARY.exists():
        raise HTTPException(503, (
            f"AnumaanSim binary not found at {_BINARY}. "
            "Build it first:\n"
            "  cd ios/AnumaanCore\n"
            "  GIT_CONFIG_PARAMETERS=\"'safe.bareRepository=all'\" "
            "  swift build --product AnumaanSim"
        ))

    path_json = json.dumps(req.path)
    cmd = [str(_BINARY), req.area, "--path", path_json, "--mode", req.mode]
    if req.area in AREAS:
        area_info = AREAS[req.area]
        bbox_str = f"{area_info['south']},{area_info['west']},{area_info['north']},{area_info['east']}"
        cmd.extend(["--bbox", bbox_str])
    cmd.append("--json")

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

    try:
        data = json.loads(result.stdout.strip())
    except json.JSONDecodeError as e:
        raise HTTPException(500, f"Bad JSON from sim: {e}\nOutput: {result.stdout[:400]}")

    if "error" in data:
        raise HTTPException(400, data["error"])

    data["areaInfo"] = AREAS[req.area]

    try:
        data_dir = Path(__file__).resolve().parent.parent / "data"
        data_dir.mkdir(parents=True, exist_ok=True)
        sim_payload = {
            "req": {"area": req.area, "path": req.path, "mode": req.mode},
            "res": data
        }
        (data_dir / "last_simulation.json").write_text(json.dumps(sim_payload, indent=2))
    except Exception as e:
        print(f"Error saving last_simulation.json: {e}")

    return data

