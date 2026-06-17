"""Live navigation session: drive the Anumaan engine along a real OSM route.

A single global :class:`NavSession` owns the navigation engine, the UDP sensor
bridge (which receives the phone's accelerometer), and a background thread that
advances dead reckoning in real time. The web frontend polls :meth:`state` to
move the map marker and reflect auto-snaps ("NODE SNAPPED") as the driver stops
at each node.

This is the zero-GPS core of the project: position comes from dead reckoning,
and the phone's IMU (over UDP) tells us when we've stopped so we can snap to the
next node and recalibrate speed.
"""

from __future__ import annotations

import math
import threading
import time

from anumaan.bridge import DEFAULT_PORT, SensorBridge, UdpSensorSender
from anumaan.fusion import HeadingCalibration, SensorFusion, _angle_diff
from anumaan.models import NavState, SensorState
from anumaan.sde import MockAccelerometer
from anumaan.state_machine import NavigationEngine
from anumaan.turn import TURN_SIGNIFICANT_DEG

BRAKE_DISTANCE_M = 40.0
STALE_SECONDS = 2.0      # no telemetry for this long → treat as stopped
TURN_CONFIRM_FRAC = 0.5  # detected ≥ this fraction of the expected turn ⇒ confirm
TURN_RANGE_M = 120.0     # only confirm a turn when near the node it belongs to


def _haversine(a: list[float], b: list[float]) -> float:
    R = 6371000.0
    lat1, lon1, lat2, lon2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * R * math.asin(min(1.0, math.sqrt(h)))


class NavSession:
    def __init__(self) -> None:
        self._lock = threading.RLock()
        self.active = False
        self.complete = False
        self.engine: NavigationEngine | None = None
        self.bridge: SensorBridge | None = None
        self.coords: list[list[float]] = []
        self._cum: list[float] = []        # cumulative meters along coords
        self._total_coords_m = 0.0
        self.total_m = 0.0
        self.node_cum: list[float] = []     # cumulative meters per milestone
        self.node_turn: list[float] = []    # expected signed turn (deg) per node
        self.node_turn_label: list[str] = []
        self.leg_bearing: list[float] = []  # compass bearing of the leg into node i
        self.leg_straight: list[bool] = []
        self._fusion: SensorFusion | None = None
        self._calib: HeadingCalibration | None = None
        self.events: list[dict] = []
        self.simulate = False
        self.port = DEFAULT_PORT
        self._stop = threading.Event()
        self._nav_thread: threading.Thread | None = None
        self._sim_thread: threading.Thread | None = None
        self._advance_requested = False   # set by the manual "I've arrived" button

    # ----- lifecycle ----------------------------------------------------
    def start(self, route: dict, *, speed: float = 11.0, simulate: bool = False,
              port: int = DEFAULT_PORT) -> dict:
        self.stop()
        with self._lock:
            milestones = route["_milestone_objs"]
            self.coords = [list(c) for c in route["coords"]]
            self._cum = self._build_cumulative(self.coords)
            self._total_coords_m = self._cum[-1] if self._cum else 0.0
            self.total_m = float(route["total_distance_m"])
            self.node_cum = [n["cumulative_m"] for n in route["nodes"]]
            self.events = []
            self.complete = False
            self.simulate = simulate
            self.port = port

            self.node_turn = [n.get("turn_angle", 0.0) for n in route["nodes"]]
            self.node_turn_label = [n.get("turn_label", "") for n in route["nodes"]]
            self.leg_bearing = [n.get("leg_bearing", 0.0) for n in route["nodes"]]
            self.leg_straight = [n.get("leg_straight", False) for n in route["nodes"]]
            self._calib = HeadingCalibration()

            sensor = SensorState()
            self._fusion = SensorFusion(sensor)
            self.bridge = SensorBridge(sensor, host="0.0.0.0", port=port,
                                       fusion=self._fusion).start()
            self.engine = NavigationEngine(
                milestones, state=NavState(estimated_speed=speed),
                sensor=sensor, start_time=0.0)
            self.active = True
            self._stop = threading.Event()

            self._nav_thread = threading.Thread(target=self._nav_loop, daemon=True)
            self._nav_thread.start()
            if simulate:
                self._sim_thread = threading.Thread(target=self._sim_loop, daemon=True)
                self._sim_thread.start()
        return self.state()

    def stop(self) -> None:
        with self._lock:
            self._stop.set()
            bridge = self.bridge
            self.active = False
        for t in (self._sim_thread, self._nav_thread):
            if t is not None:
                t.join(timeout=1.5)
        if bridge is not None:
            bridge.stop()
        with self._lock:
            self.bridge = None
            self._nav_thread = None
            self._sim_thread = None

    # ----- threads ------------------------------------------------------
    def _nav_loop(self) -> None:
        engine = self.engine
        start = time.monotonic()
        last_overdue = -1
        while not self._stop.is_set() and engine is not None and not engine.is_complete:
            now = time.monotonic() - start

            sensor = engine.sensor

            # Manual "I've arrived" override: snap to the current target node and
            # recalibrate speed from how long the leg actually took. Processed in
            # this thread so the engine is only ever touched from one place.
            if self._advance_requested:
                self._advance_requested = False
                self._confirm(engine, now, "manually marked arrival")
                last_overdue = -1
                continue

            # Turn confirmation: a sensed turn of roughly the expected size at the
            # node we're approaching confirms we navigated it — advance. Matched on
            # MAGNITUDE (the gyro's left/right sign depends on unknown phone
            # orientation, so it's shown but not required).
            idx = engine.state.current_milestone_index
            expected = self.node_turn[idx] if idx < len(self.node_turn) else 0.0
            detected = sensor.heading_change_deg
            if (sensor.has_gyro and abs(expected) >= TURN_SIGNIFICANT_DEG
                    and engine.remaining_distance() <= TURN_RANGE_M
                    and abs(detected) >= TURN_CONFIRM_FRAC * abs(expected)):
                side = "right" if detected > 0 else "left"
                self._confirm(engine, now,
                              f"TURN CONFIRMED ({abs(detected):.0f}° {side})")
                last_overdue = -1
                continue

            # Telemetry-gated motion:
            #   * advance only with FRESH telemetry that says we're moving;
            #   * auto-snap only on a GENUINE stationary reading (never on stale
            #     data — otherwise "no phone" would snap milestones by itself).
            stale = sensor.packets == 0 or (time.monotonic() - sensor.last_update) > STALE_SECONDS
            genuine_stationary = sensor.is_stationary and not stale
            is_moving = (not stale) and (not sensor.is_stationary)

            # Auto-calibrate the phone's heading offset (no user prompt): while
            # driving a known-straight leg and not turning, the true bearing is
            # the leg's bearing, so compass − leg_bearing is the offset.
            if (self._calib is not None and sensor.has_mag and is_moving
                    and abs(sensor.yaw_rate_dps) < 5.0
                    and idx < len(self.leg_straight) and self.leg_straight[idx]):
                implied = (sensor.heading_deg - self.leg_bearing[idx]) % 360.0
                # Once calibrated, reject samples whose implied offset is far from
                # the established one — a wrong turn must NOT corrupt the offset
                # (and is instead surfaced as off_route).
                if (not self._calib.calibrated
                        or abs(_angle_diff(implied, self._calib.offset)) < 40.0):
                    self._calib.add(sensor.heading_deg, self.leg_bearing[idx])

            event = engine.tick(now, is_stationary=genuine_stationary, is_moving=is_moving)
            if event is not None:
                if event.automated:
                    self._log(f"NODE SNAPPED → {event.milestone.name or event.milestone.id}",
                              snapped=True, v_true=event.v_true)
                    self._reset_leg_detectors()
                    last_overdue = -1
                elif idx != last_overdue:
                    label = self.node_turn_label[idx] if idx < len(self.node_turn_label) else ""
                    name = event.milestone.name or event.milestone.id
                    msg = (f"reached {name} — expected turn: {label}; turn or tap arrived"
                           if abs(expected) >= TURN_SIGNIFICANT_DEG
                           else f"reached {name} — stop or tap arrived to continue")
                    self._log(msg, snapped=False)
                    last_overdue = idx
            time.sleep(0.05)
        with self._lock:
            self.complete = engine.is_complete if engine else False

    def _sim_loop(self) -> None:
        """In-process emulated phone: stream real UDP accel datagrams locally."""
        engine = self.engine
        accel = MockAccelerometer(seed=7)
        with UdpSensorSender("127.0.0.1", self.port) as sender:
            while not self._stop.is_set() and engine is not None and not engine.is_complete:
                moving = engine.remaining_distance() > BRAKE_DISTANCE_M
                sender.send(*accel.sample(moving=moving))
                time.sleep(1.0 / 50.0)

    # ----- helpers ------------------------------------------------------
    def _reset_leg_detectors(self) -> None:
        # Resets the fusion engine: moving/stopped window + heading-change baseline.
        if self.bridge is not None:
            self.bridge.reset_detector()

    def _confirm(self, engine: NavigationEngine, now: float, label: str) -> None:
        """Confirm arrival at the current target node and reset per-leg detectors."""
        reached = engine.next_milestone
        v = engine.confirm_arrival(now)
        self._log(f"{label} → {reached.name or reached.id}", snapped=True, v_true=v)
        self._reset_leg_detectors()

    def _log(self, message: str, *, snapped: bool, v_true: float | None = None) -> None:
        with self._lock:
            self.events.append({
                "t": time.time(), "message": message, "snapped": snapped,
                "v_true": round(v_true, 2) if v_true is not None else None,
                "milestone_index": self.engine.state.current_milestone_index
                if self.engine else 0,
            })

    @staticmethod
    def _build_cumulative(coords: list[list[float]]) -> list[float]:
        cum = [0.0]
        for a, b in zip(coords[:-1], coords[1:]):
            cum.append(cum[-1] + _haversine(a, b))
        return cum

    def _position_at(self, traveled_m: float) -> list[float]:
        """Interpolate a lat/lon along the route polyline at a traveled distance."""
        if not self.coords:
            return [0.0, 0.0]
        if self.total_m <= 0:
            return self.coords[0]
        frac = max(0.0, min(1.0, traveled_m / self.total_m))
        target = frac * self._total_coords_m
        # binary-ish linear scan (routes are short enough)
        for i in range(1, len(self._cum)):
            if self._cum[i] >= target:
                seg = self._cum[i] - self._cum[i - 1]
                t = 0.0 if seg <= 0 else (target - self._cum[i - 1]) / seg
                a, b = self.coords[i - 1], self.coords[i]
                return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]
        return self.coords[-1]

    # ----- external (HTTP) telemetry ------------------------------------
    def ingest(self, data: bytes) -> int:
        """Feed an HTTP-posted sensor body into the live bridge. Returns packets."""
        bridge = self.bridge
        if bridge is None:
            return 0
        bridge.ingest(data, addr=("http", 0))
        return bridge.sensor.packets

    def request_advance(self) -> bool:
        """Manual 'I've arrived' — ask the nav loop to confirm the current node."""
        with self._lock:
            if self.engine is None or self.engine.is_complete:
                return False
            self._advance_requested = True
            return True

    # ----- snapshot -----------------------------------------------------
    def state(self) -> dict:
        with self._lock:
            if self.engine is None:
                return {"active": False}
            st = self.engine.state
            idx = st.current_milestone_index
            base = self.node_cum[idx - 1] if 0 < idx <= len(self.node_cum) else 0.0
            traveled = base + (0.0 if self.engine.is_complete else st.accumulated_distance)
            sensor = self.engine.sensor
            age = (time.monotonic() - sensor.last_update) if sensor.packets else None
            connected = sensor.packets > 0 and age is not None and age < STALE_SECONDS
            moving = connected and not sensor.is_stationary
            nxt = (None if self.engine.is_complete
                   else (self.engine.next_milestone.name or self.engine.next_milestone.id))
            turn_angle = self.node_turn[idx] if idx < len(self.node_turn) else 0.0
            turn_label = self.node_turn_label[idx] if idx < len(self.node_turn_label) else ""
            # Calibrated true heading + wrong-way check.
            calibrated = self._calib is not None and self._calib.calibrated
            true_heading = (round(self._calib.true_heading(sensor.heading_deg), 1)
                            if calibrated and sensor.has_mag else None)
            off_route = False
            if (true_heading is not None and not sensor.is_stationary
                    and abs(sensor.yaw_rate_dps) < 10.0 and idx < len(self.leg_bearing)):
                off_route = abs(_angle_diff(true_heading, self.leg_bearing[idx])) > 60.0
            return {
                "active": self.active,
                "complete": self.complete or self.engine.is_complete,
                "next_milestone": nxt,
                "next_turn_angle": turn_angle,
                "next_turn_label": turn_label,
                "heading_change_deg": round(sensor.heading_change_deg, 1),
                "heading_deg": round(sensor.heading_deg, 1),
                "has_gyro": sensor.has_gyro,
                "has_mag": sensor.has_mag,
                "calibrated": calibrated,
                "heading_offset": round(self._calib.offset, 1) if calibrated else None,
                "true_heading": true_heading,
                "leg_bearing": self.leg_bearing[idx] if idx < len(self.leg_bearing) else None,
                "off_route": off_route,
                "simulate": self.simulate,
                "port": self.port,
                "position": self._position_at(traveled),
                "traveled_m": round(traveled, 1),
                "total_m": round(self.total_m, 1),
                "current_index": idx,
                "milestone_count": len(self.engine.route) - 1,
                "estimated_speed": round(st.estimated_speed, 2),
                "accumulated_distance": round(st.accumulated_distance, 1),
                "is_stationary": sensor.is_stationary,
                "accel_variance": round(sensor.accel_variance, 4),
                "raw_accel": [round(v, 3) for v in sensor.raw_accel],
                "packets": sensor.packets,
                "telemetry_connected": connected,
                "telemetry_age_s": round(age, 1) if age is not None else None,
                "moving": moving,
                "events": self.events[-12:],
            }


# Single global session — only one UDP nav can run at a time.
session = NavSession()
