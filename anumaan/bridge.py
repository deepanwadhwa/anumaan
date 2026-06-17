"""Sensor ingestion layer — the UDP telemetry bridge (spec.xml rule 2).

The development laptop has no IMU, so accelerometer data arrives over the local
network from a smartphone (e.g. the *Sensor Logger* app pushing JSON to a UDP
port over a mobile hotspot). This module is **fully decoupled** from the
navigation state machine: it only knows about :class:`SensorState` and the
:class:`StationaryDetector`. The state machine reads the resulting
``SensorState`` flags without ever touching a socket.

Wire format: each UDP datagram is a JSON object carrying an acceleration sample.
The parser is tolerant of a few shapes:

    {"accel_x": 0.01, "accel_y": -0.02, "accel_z": 0.98}
    {"x": ..., "y": ..., "z": ...}
    {"messages": [{"name": "accelerometer", "values": {"x":..,"y":..,"z":..}}]}

Acceleration is interpreted in *g*. Only the binary stationary decision is
derived from it — never a continuous velocity (spec boundary).
"""

from __future__ import annotations

import json
import socket
import threading
import time
from typing import Callable

from .models import SensorState
from .sde import StationaryDetector

DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8000

# (x, y, z) extracted from a payload, or None if it isn't an accel sample.
Accel = tuple[float, float, float]


def _xyz(d: object, prefixes=("", "accel_", "gyro_", "a", "g")) -> Accel | None:
    """Pull an (x, y, z) triple out of a values dict, tolerant of key styles."""
    if not isinstance(d, dict):
        return None
    for kx, ky, kz in (("x", "y", "z"), ("accel_x", "accel_y", "accel_z"),
                       ("gyro_x", "gyro_y", "gyro_z"), ("ax", "ay", "az"),
                       ("gx", "gy", "gz")):
        if kx in d and ky in d and kz in d:
            try:
                return float(d[kx]), float(d[ky]), float(d[kz])
            except (TypeError, ValueError):
                return None
    return None


def _batch_for(obj: object, names: tuple[str, ...], flat_keys: tuple) -> list[Accel]:
    """All samples for a sensor — from a flat single sample or a SL batch."""
    if not isinstance(obj, dict):
        return []
    for kx, ky, kz in flat_keys:
        if kx in obj and ky in obj and kz in obj:
            try:
                return [(float(obj[kx]), float(obj[ky]), float(obj[kz]))]
            except (TypeError, ValueError):
                return []
    out: list[Accel] = []
    for key in ("messages", "payload", "data"):
        batch = obj.get(key)
        if isinstance(batch, list):
            for msg in batch:
                if isinstance(msg, dict) and str(msg.get("name", "")).lower() in names:
                    s = _xyz(msg.get("values", msg))
                    if s is not None:
                        out.append(s)
            if out:
                return out
    return out


def parse_accel_batch(obj: object) -> list[Accel]:
    """Every accelerometer sample in a payload (flat or Sensor Logger batch)."""
    return _batch_for(obj, ("accelerometer",),
                      (("accel_x", "accel_y", "accel_z"), ("x", "y", "z"),
                       ("ax", "ay", "az")))


def parse_gyro_batch(obj: object) -> list[Accel]:
    """Every gyroscope sample (rad/s) in a payload (flat or Sensor Logger batch)."""
    return _batch_for(obj, ("gyroscope", "gyroscopeuncalibrated"),
                      (("gyro_x", "gyro_y", "gyro_z"), ("gx", "gy", "gz")))


def parse_mag_batch(obj: object) -> list[Accel]:
    """Every magnetometer sample (µT) in a payload (flat or Sensor Logger batch)."""
    return _batch_for(obj, ("magnetometer", "magnetometeruncalibrated"),
                      (("mag_x", "mag_y", "mag_z"), ("mx", "my", "mz")))


def parse_accel(obj: object) -> Accel | None:
    """Best-effort extraction of a single ``(x, y, z)`` accel vector."""
    samples = parse_accel_batch(obj)
    return samples[0] if samples else None


class SensorBridge:
    """Background UDP listener that feeds a :class:`SensorState` / SDE.

    Start it with :meth:`start` (or use it as a context manager). It binds a UDP
    socket, spawns a daemon thread, and for every valid datagram updates
    ``sensor.raw_accel`` and pushes the sample through the stationary detector.
    """

    def __init__(
        self,
        sensor: SensorState | None = None,
        detector: StationaryDetector | None = None,
        host: str = DEFAULT_HOST,
        port: int = DEFAULT_PORT,
        *,
        turn_detector=None,
        fusion=None,
        on_sample: Callable[[Accel, SensorState, tuple], None] | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        # ``fusion`` (a SensorFusion) is the modern path: it owns moving/stopped
        # AND heading from accel+gyro+mag. ``detector``/``turn_detector`` are the
        # legacy split path, kept for tests and standalone use.
        self.fusion = fusion
        if sensor is None:
            sensor = (fusion.sensor if fusion is not None else
                      detector.sensor if detector is not None else SensorState())
        self.sensor = sensor
        if fusion is None:
            self.detector = detector or StationaryDetector(sensor)
            if self.detector.sensor is not sensor:
                raise ValueError("detector and sensor must share the same SensorState")
        else:
            self.detector = None
        self.turn_detector = turn_detector   # optional TurnDetector (gyro yaw)
        self.host = host
        self.port = port
        self.on_sample = on_sample
        self._clock = clock
        self._sock: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self.bad_packets = 0

    # ----- lifecycle ----------------------------------------------------
    def start(self) -> "SensorBridge":
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((self.host, self.port))
        # Reflect the actual bound port back (useful when binding port 0).
        self.port = sock.getsockname()[1]
        sock.settimeout(0.5)
        self._sock = sock
        self._thread = threading.Thread(target=self._run, name="sensor-bridge",
                                        daemon=True)
        self._thread.start()
        return self

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2.0)
        if self._sock is not None:
            self._sock.close()
            self._sock = None

    def __enter__(self) -> "SensorBridge":
        return self.start()

    def __exit__(self, *exc) -> None:
        self.stop()

    def reset_detector(self) -> None:
        """Clear the rolling buffer/verdict under the lock (e.g. after a snap)."""
        with self._lock:
            if self.fusion is not None:
                self.fusion.reset_leg()
            elif self.detector is not None:
                self.detector.reset()

    # ----- receive loop -------------------------------------------------
    def _run(self) -> None:
        assert self._sock is not None
        while not self._stop.is_set():
            try:
                data, addr = self._sock.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                break
            self.ingest(data, addr)

    def ingest(self, data: bytes, addr: tuple = ("", 0)) -> Accel | None:
        """Parse one datagram/POST body and fold its samples into the SDE.

        Accepts a single sample (UDP) or a Sensor Logger batch (HTTP) with many
        samples. Exposed (not just used by the receive loop) so it can be
        unit-tested and driven from an in-process or HTTP feed without a socket.
        Returns the most recent sample, or None if nothing parseable was found.
        """
        try:
            obj = json.loads(data.decode("utf-8").strip())
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.bad_packets += 1
            return None
        samples = parse_accel_batch(obj)
        gyro = parse_gyro_batch(obj)
        mag = parse_mag_batch(obj)
        if not samples and not gyro and not mag:
            self.bad_packets += 1
            return None

        now = self._clock()
        with self._lock:
            if self.fusion is not None:
                # Order matters: accel (gravity) first, then gyro predict, then
                # mag correct — so heading uses the freshest gravity.
                for s in samples:
                    self.fusion.add_accel(s[0], s[1], s[2], now)
                for s in gyro:
                    self.fusion.add_gyro(s[0], s[1], s[2], now)
                for s in mag:
                    self.fusion.add_mag(s[0], s[1], s[2], now)
            else:
                for s in samples:
                    self.detector.add_sample(s[0], s[1], s[2], now)
                if samples:
                    self.sensor.raw_accel = samples[-1]
                if gyro and self.turn_detector is not None:
                    gravity = self.sensor.raw_accel
                    for gx, gy, gz in gyro:
                        self.turn_detector.add_gyro(gx, gy, gz, gravity, now)
            self.sensor.packets += len(samples) + len(gyro) + len(mag)
            self.sensor.last_update = now
        if self.on_sample is not None and samples:
            self.on_sample(samples[-1], self.sensor, addr)
        return samples[-1] if samples else None


# --------------------------------------------------------------------------
# Phone simulator — send telemetry to a bridge for testing without a device.
# --------------------------------------------------------------------------
def encode_sample(x: float, y: float, z: float) -> bytes:
    """Encode an accel sample as a JSON datagram (the wire format we accept)."""
    return json.dumps({"accel_x": x, "accel_y": y, "accel_z": z}).encode("utf-8")


class UdpSensorSender:
    """A tiny UDP client that pushes accel samples to a bridge (stand-in phone)."""

    def __init__(self, host: str = "127.0.0.1", port: int = DEFAULT_PORT) -> None:
        self.host = host
        self.port = port
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def send(self, x: float, y: float, z: float) -> None:
        self._sock.sendto(encode_sample(x, y, z), (self.host, self.port))

    def close(self) -> None:
        self._sock.close()

    def __enter__(self) -> "UdpSensorSender":
        return self

    def __exit__(self, *exc) -> None:
        self.close()
