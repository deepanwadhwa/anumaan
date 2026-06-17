#!/usr/bin/env python3
"""Launch the Anumaan local navigation web app.

    python run_app.py            # serve on http://127.0.0.1:8080
    python run_app.py --host 0.0.0.0 --port 8080

Then open the printed URL in your browser. The phone streams accelerometer JSON
to UDP port 8000 (shown in the Navigate screen) over your local network.
"""

import argparse
import socket

import uvicorn


def _local_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8080)
    args = p.parse_args()

    print("\n  Anumaan offline navigation")
    print(f"  → open  http://{args.host}:{args.port}")
    if args.host in ("0.0.0.0", _local_ip()):
        print(f"  → LAN   http://{_local_ip()}:{args.port}")
    print("  phone IMU → UDP :8000 (shown in the Navigate screen)\n")
    uvicorn.run("app.server:app", host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
