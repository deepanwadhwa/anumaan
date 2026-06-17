#!/usr/bin/env python3
"""Run the last saved simulation offline from the terminal.

Loads the path and area from data/last_simulation.json and executes the AnumaanSim Swift CLI.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

def main():
    root_dir = Path(__file__).resolve().parent
    sim_file = root_dir / "data" / "last_simulation.json"
    
    if not sim_file.exists():
        print(f"Error: {sim_file} does not exist yet.")
        print("Please open the browser, draw a walk, and click 'Run Sim' at least once to save a run.")
        sys.exit(1)
        
    try:
        data = json.loads(sim_file.read_text())
    except Exception as e:
        print(f"Error reading {sim_file}: {e}")
        sys.exit(1)
        
    req = data.get("req", {})
    area = req.get("area", "clemson")
    path = req.get("path")
    mode = req.get("mode", "road")
    
    if not path:
        print("Error: No path found in saved simulation data.")
        sys.exit(1)
        
    binary = root_dir / "ios" / "AnumaanCore" / ".build" / "debug" / "AnumaanSim"
    if not binary.exists():
        print(f"Error: AnumaanSim binary not found at {binary}")
        print("Build it first:")
        print("  cd ios/AnumaanCore && swift build --product AnumaanSim")
        sys.exit(1)
        
    path_json = json.dumps(path)
    cmd = [str(binary), area, "--path", path_json, "--mode", mode]
    
    # Check if user passed --json to run_last_sim.py
    if "--json" in sys.argv:
        cmd.append("--json")
        
    print(f"Running simulation offline using AnumaanSim CLI...")
    print(f"Command: {binary.name} {area} --path '[...]'\n")
    
    env = {**os.environ, "GIT_CONFIG_PARAMETERS": "'safe.bareRepository=all'"}
    result = subprocess.run(cmd, capture_output=False, env=env)
    sys.exit(result.returncode)

if __name__ == "__main__":
    main()
