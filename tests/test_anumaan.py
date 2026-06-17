"""Tests covering the spec business rules, the SDE, and the core loop.

Run with:  python -m pytest   (or)   python tests/test_anumaan.py
"""

from __future__ import annotations

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import time

from anumaan.bridge import (
    SensorBridge,
    UdpSensorSender,
    encode_sample,
    parse_accel,
)
from anumaan.models import Milestone, NavState, SensorState
from anumaan.sde import (
    STATIONARY_THRESHOLD,
    MockAccelerometer,
    StationaryDetector,
    accel_magnitude,
)
from anumaan.state_machine import EventKind, NavigationEngine


class _FakeClock:
    """Controllable monotonic clock for deterministic SDE timing in tests."""

    def __init__(self) -> None:
        self.t = 0.0

    def __call__(self) -> float:
        return self.t

    def tick(self, dt: float = 0.02) -> float:
        self.t += dt
        return self.t


def _simple_route():
    return [
        Milestone("o", "origin", 0.0, name="Origin"),
        Milestone("a", "stop_sign", 100.0, name="A"),
        Milestone("b", "traffic_light", 200.0, name="B"),
        Milestone("c", "destination", 300.0, name="Dest"),
    ]


def _simple_engine(speed=10.0):
    return NavigationEngine(_simple_route(),
                            state=NavState(estimated_speed=speed), start_time=0.0)


# --- Rule 1: expected time -------------------------------------------------
def test_rule1_expected_time():
    eng = _simple_engine(speed=10.0)
    assert math.isclose(eng.expected_time(), 10.0)  # 100 m / 10 m/s


# --- core loop / dead reckoning -------------------------------------------
def test_tick_accumulates_and_fallback_prompts():
    eng = _simple_engine(speed=10.0)
    assert eng.tick(5.0) is None  # 50 m travelled, not yet at 100
    assert math.isclose(eng.state.accumulated_distance, 50.0)
    ev = eng.tick(10.0)  # 100 m, SDE silent -> rule 4 fallback prompt
    assert ev is not None and ev.kind == EventKind.FALLBACK_PROMPT
    assert ev.milestone.id == "a" and ev.automated is False


# --- Rule 3: speed smoothing ----------------------------------------------
def test_rule3_smoothing_slower_leg():
    eng = _simple_engine(speed=10.0)
    eng.tick(10.0)
    v = eng.confirm_arrival(20.0)  # leg took 20 s -> V_true = 5 m/s
    assert math.isclose(v, 5.0)
    assert math.isclose(eng.state.estimated_speed, 8.5)  # 10*0.7 + 5*0.3
    assert eng.state.current_milestone_index == 2


def test_rule3_smoothing_faster_leg():
    eng = _simple_engine(speed=10.0)
    eng.tick(10.0)
    v = eng.confirm_arrival(5.0)  # leg took 5 s -> V_true = 20 m/s
    assert math.isclose(v, 20.0)
    assert math.isclose(eng.state.estimated_speed, 13.0)  # 10*0.7 + 20*0.3


def test_deny_keeps_timer_and_index():
    eng = _simple_engine(speed=10.0)
    eng.tick(10.0)
    idx_before = eng.state.current_milestone_index
    eng.deny_arrival(10.0)
    assert eng.state.current_milestone_index == idx_before
    assert eng.tick(10.0) is None      # same instant -> no re-prompt
    assert eng.tick(12.0) is not None  # more time -> prompt again


# --- Rule 2: SDE auto-snap -------------------------------------------------
def test_within_snap_range():
    eng = _simple_engine(speed=10.0)
    eng.tick(4.0)   # 40 m of a 100 m leg -> 60 m gap, not in range
    assert not eng.within_snap_range()
    eng.tick(6.0)   # 60 m -> 40 m gap, within 50 m
    assert eng.within_snap_range()


def test_rule2_autosnap_when_stationary_in_range():
    eng = _simple_engine(speed=10.0)
    eng.tick(6.0)  # 60 m -> within snap range, not yet at 100 m
    assert eng.state.current_milestone_index == 1
    ev = eng.tick(7.0, is_stationary=True)  # SDE says stopped, within 50 m
    assert ev is not None and ev.kind == EventKind.AUTO_SNAP
    assert ev.automated is True and ev.v_true is not None
    assert eng.state.current_milestone_index == 2  # advanced automatically


def test_autosnap_ignored_when_out_of_range():
    eng = _simple_engine(speed=10.0)
    # 30 m into a 100 m leg: stationary but 70 m from the node -> no snap.
    ev = eng.tick(3.0, is_stationary=True)
    assert ev is None
    assert eng.state.current_milestone_index == 1


# --- SDE internals ---------------------------------------------------------
def test_accel_magnitude():
    assert math.isclose(accel_magnitude(0.0, 0.0, 1.0), 1.0)
    assert math.isclose(accel_magnitude(3.0, 4.0, 0.0), 5.0)


def test_detector_flatline_goes_stationary_then_motion_clears():
    sensor = SensorState()
    det = StationaryDetector(sensor)
    accel = MockAccelerometer(seed=1)
    dt, now = 0.02, 0.0

    # Feed ~3 s of "stopped" samples: variance collapses, stationary latches.
    for _ in range(150):
        now += dt
        det.add_sample(*accel.sample(moving=False), now=now)
    assert sensor.accel_variance < STATIONARY_THRESHOLD
    assert sensor.is_stationary is True

    # Now feed "moving" samples: variance climbs back, stationary clears.
    for _ in range(150):
        now += dt
        det.add_sample(*accel.sample(moving=True), now=now)
    assert sensor.accel_variance > STATIONARY_THRESHOLD
    assert sensor.is_stationary is False


def test_detector_requires_hold_time():
    sensor = SensorState()
    det = StationaryDetector(sensor)
    accel = MockAccelerometer(seed=2)
    now = 0.0
    # A couple of flat samples is well under the 1 s hold -> not yet stationary.
    for _ in range(5):
        now += 0.02
        det.add_sample(*accel.sample(moving=False), now=now)
    assert sensor.is_stationary is False


def test_shared_sensor_drives_engine_autosnap():
    """End-to-end: SDE writes is_stationary, engine reads it via the shared state."""
    sensor = SensorState()
    det = StationaryDetector(sensor)
    accel = MockAccelerometer(seed=3)
    eng = NavigationEngine(_simple_route(),
                           state=NavState(estimated_speed=10.0),
                           sensor=sensor, start_time=0.0)
    now = 0.0
    snapped = False
    for _ in range(20000):
        now += 0.02
        moving = eng.remaining_distance() > 40.0
        det.add_sample(*accel.sample(moving=moving), now=now)
        ev = eng.tick(now)
        if ev is not None and ev.kind == EventKind.AUTO_SNAP:
            snapped = True
            break
    assert snapped, "expected the SDE to auto-snap the first milestone"
    assert eng.state.current_milestone_index == 2


def test_full_route_completes_via_fallback():
    eng = _simple_engine(speed=10.0)
    t = 0.0
    while not eng.is_complete:
        t += eng.expected_time() + 1.0
        if eng.tick(t):
            eng.confirm_arrival(t)
    assert eng.is_complete


# --- Rule 2: UDP sensor bridge --------------------------------------------
def test_parse_accel_shapes():
    assert parse_accel({"accel_x": 1, "accel_y": 2, "accel_z": 3}) == (1.0, 2.0, 3.0)
    assert parse_accel({"x": 0.1, "y": 0.2, "z": 0.3}) == (0.1, 0.2, 0.3)
    nested = {"messages": [{"name": "accelerometer",
                            "values": {"x": 0.0, "y": 0.0, "z": 1.0}}]}
    assert parse_accel(nested) == (0.0, 0.0, 1.0)
    assert parse_accel({"foo": "bar"}) is None
    assert parse_accel("not a dict") is None


def test_bridge_ingest_drives_stationary_with_fake_clock():
    clock = _FakeClock()
    sensor = SensorState()
    bridge = SensorBridge(sensor, clock=clock)  # no socket; call ingest directly
    accel = MockAccelerometer(seed=5)

    for _ in range(200):  # ~4 s of flat samples
        clock.tick(0.02)
        bridge.ingest(encode_sample(*accel.sample(moving=False)))

    assert sensor.packets == 200
    assert sensor.is_stationary is True
    assert sensor.accel_variance < STATIONARY_THRESHOLD
    # raw_accel reflects the latest sample (gravity on z).
    assert abs(sensor.raw_accel[2] - 1.0) < 0.1


def test_parse_accel_batch_sensorlogger():
    from anumaan.bridge import parse_accel_batch
    payload = {"messages": [
        {"name": "accelerometer", "values": {"x": 0.1, "y": 0.2, "z": 0.98}},
        {"name": "gravity", "values": {"x": 0, "y": 0, "z": 9.8}},
        {"name": "accelerometer", "values": {"x": -0.1, "y": 0.0, "z": 1.01}},
    ]}
    samples = parse_accel_batch(payload)
    assert samples == [(0.1, 0.2, 0.98), (-0.1, 0.0, 1.01)]  # gravity skipped


def test_motion_gate_holds_position_when_stationary():
    eng = _simple_engine(speed=10.0)
    eng.tick(2.0, is_stationary=False)            # moving -> advances
    moved = eng.state.accumulated_distance
    assert moved > 0
    eng.tick(5.0, is_stationary=True)             # stationary -> must NOT advance
    assert eng.state.accumulated_distance == moved
    eng.tick(7.0, is_stationary=False)            # moving again -> advances
    assert eng.state.accumulated_distance > moved


def test_car_holds_at_node_until_confirmed():
    # Dead reckoning must stop AT the next milestone and never glide past it.
    eng = _simple_engine(speed=10.0)        # first leg is 100 m
    for i in range(1, 40):                   # plenty of moving time
        eng.tick(float(i), is_stationary=False, is_moving=True)
    assert eng.state.accumulated_distance == 100.0   # capped at the node
    assert eng.remaining_distance() == 0.0
    assert eng.state.current_milestone_index == 1     # never advanced on its own
    # A manual confirm is what moves it onward.
    eng.confirm_arrival(40.0)
    assert eng.state.current_milestone_index == 2


def test_no_telemetry_never_snaps_or_explodes_speed():
    # Reproduces the screenshot bug: a short first leg + no telemetry must NOT
    # auto-snap, must not move, and must not corrupt the speed estimate.
    route = [
        Milestone("o", "origin", 0.0, name="Start"),
        Milestone("a", "stop_sign", 30.0, name="A"),   # short leg, inside snap range
        Milestone("b", "destination", 300.0, name="Dest"),
    ]
    eng = NavigationEngine(route, state=NavState(estimated_speed=11.0), start_time=0.0)
    t = 0.0
    for _ in range(400):  # ~20 s of "no telemetry" ticks
        t += 0.05
        ev = eng.tick(t, is_stationary=False, is_moving=False)
        assert ev is None
    assert eng.state.current_milestone_index == 1      # never advanced
    assert eng.state.accumulated_distance == 0.0       # never moved
    assert eng.state.estimated_speed == 11.0           # never corrupted


def test_short_leg_does_not_instasnap_before_min_leg_time():
    route = [
        Milestone("o", "origin", 0.0, name="Start"),
        Milestone("a", "stop_sign", 30.0, name="A"),
        Milestone("b", "destination", 300.0, name="Dest"),
    ]
    eng = NavigationEngine(route, state=NavState(estimated_speed=11.0), start_time=0.0)
    # Genuinely stationary and within range, but the leg just began → no snap.
    assert eng.tick(1.0, is_stationary=True, is_moving=False) is None
    assert eng.state.current_milestone_index == 1
    # After the minimum leg time, it snaps — with a *sane* (clamped) speed.
    ev = eng.tick(4.0, is_stationary=True, is_moving=False)
    assert ev is not None and ev.kind == EventKind.AUTO_SNAP
    assert eng.state.estimated_speed <= 45.0


def test_bridge_rejects_bad_payloads():
    bridge = SensorBridge(SensorState())
    assert bridge.ingest(b"not json") is None
    assert bridge.ingest(b'{"temperature": 21}') is None
    assert bridge.bad_packets == 2
    assert bridge.sensor.packets == 0


def test_bridge_udp_roundtrip():
    """End-to-end over a real UDP socket: phone-sim -> bridge -> SensorState."""
    bridge = SensorBridge(SensorState(), host="127.0.0.1", port=0).start()
    try:
        with UdpSensorSender("127.0.0.1", bridge.port) as sender:
            for _ in range(25):
                sender.send(0.0, 0.0, 1.0)
                time.sleep(0.002)
            deadline = time.monotonic() + 2.0
            while bridge.sensor.packets < 1 and time.monotonic() < deadline:
                time.sleep(0.01)
    finally:
        got = bridge.sensor.packets
        raw = bridge.sensor.raw_accel
        bridge.stop()
    assert got >= 1
    assert raw == (0.0, 0.0, 1.0)


def test_bridge_drives_engine_autosnap():
    """Telemetry ingested via the bridge auto-snaps the engine (decoupled)."""
    clock = _FakeClock()
    sensor = SensorState()
    detector = StationaryDetector(sensor)
    bridge = SensorBridge(sensor, detector, clock=clock)
    eng = NavigationEngine(_simple_route(),
                           state=NavState(estimated_speed=10.0),
                           sensor=sensor, start_time=0.0)
    accel = MockAccelerometer(seed=6)

    eng.tick(6.0)  # dead reckon to 60 m of 100 m -> within 50 m snap range
    assert eng.within_snap_range()

    # Stream "stopped" telemetry through the bridge until the SDE latches.
    for _ in range(200):
        clock.tick(0.02)
        bridge.ingest(encode_sample(*accel.sample(moving=False)))
        if sensor.is_stationary:
            break
    assert sensor.is_stationary is True

    ev = eng.tick(6.5)  # engine reads the shared SensorState and snaps
    assert ev is not None and ev.kind == EventKind.AUTO_SNAP
    assert eng.state.current_milestone_index == 2


# --- Turn Detection Engine (gyroscope) ------------------------------------
def test_turn_angle_geometry():
    from anumaan.turn import classify_turn, turn_angle
    # Travel north, then east → a right (clockwise) turn ≈ +90°.
    right = turn_angle((0.0, 0.0), (0.001, 0.0), (0.001, 0.001))
    assert 80 < right < 100 and classify_turn(right) == "right"
    # Travel north, then west → a left turn ≈ -90°.
    left = turn_angle((0.0, 0.0), (0.001, 0.0), (0.001, -0.001))
    assert -100 < left < -80 and classify_turn(left) == "left"
    # Nearly straight.
    straight = turn_angle((0.0, 0.0), (0.001, 0.0), (0.002, 0.00001))
    assert classify_turn(straight) == "straight"


def test_turn_detector_integrates_90_degrees():
    from anumaan.turn import TurnDetector
    sensor = SensorState()
    det = TurnDetector(sensor)
    # Phone flat (gravity on +z). Yaw at 30°/s for 3 s ⇒ ~90° heading change.
    yaw_rate = math.radians(30.0)        # rad/s about vertical
    gravity = (0.0, 0.0, 9.8)
    now = 0.0
    for _ in range(150):                  # 3 s at 50 Hz
        now += 0.02
        det.add_gyro(0.0, 0.0, yaw_rate, gravity, now)
    assert 85 <= abs(sensor.heading_change_deg) <= 95
    assert sensor.has_gyro is True
    det.reset()
    assert sensor.heading_change_deg == 0.0


def test_turn_detector_ignores_noise_when_still():
    from anumaan.turn import TurnDetector
    sensor = SensorState()
    det = TurnDetector(sensor)
    gravity = (0.0, 0.0, 9.8)
    now = 0.0
    for _ in range(150):                  # tiny jitter under the deadband
        now += 0.02
        det.add_gyro(0.0, 0.0, math.radians(1.0), gravity, now)
    assert abs(sensor.heading_change_deg) < 2.0   # no phantom drift


def test_parse_gyro_batch_sensorlogger():
    from anumaan.bridge import parse_gyro_batch
    payload = {"messages": [
        {"name": "gyroscope", "values": {"x": 0.1, "y": -0.2, "z": 0.5}},
        {"name": "accelerometer", "values": {"x": 0, "y": 0, "z": 9.8}},
        {"name": "gyroscope", "values": {"x": 0.0, "y": 0.0, "z": 0.4}},
    ]}
    assert parse_gyro_batch(payload) == [(0.1, -0.2, 0.5), (0.0, 0.0, 0.4)]


# --- Sensor fusion (accel + gyro + magnetometer) --------------------------
def test_parse_mag_batch_sensorlogger():
    from anumaan.bridge import parse_mag_batch
    payload = {"messages": [
        {"name": "magnetometer", "values": {"x": 12.0, "y": -3.0, "z": -40.0}},
        {"name": "accelerometer", "values": {"x": 0, "y": 0, "z": 9.8}},
    ]}
    assert parse_mag_batch(payload) == [(12.0, -3.0, -40.0)]


def test_tilt_compass_change_tracks_horizontal_rotation():
    from anumaan.fusion import _angle_diff, tilt_compensated_heading
    g = (0.0, 0.0, 9.8)                       # phone flat
    h_a = tilt_compensated_heading(g, (20.0, 0.0, -40.0))
    h_b = tilt_compensated_heading(g, (0.0, 20.0, -40.0))   # field rotated 90°
    assert 80 < abs(_angle_diff(h_b, h_a)) < 100
    assert 0 <= h_a < 360


def test_fusion_heading_is_drift_free_with_magnetometer():
    from anumaan.fusion import SensorFusion
    sensor = SensorState()
    f = SensorFusion(sensor)
    grav, mag = (0.0, 0.0, 9.8), (20.0, 0.0, -40.0)   # both constant ⇒ no real turn
    yaw_bias = math.radians(5.0)              # gyro insists we're turning 5°/s
    now = 0.0
    for _ in range(250):                       # 5 s
        now += 0.02
        f.add_accel(*grav, now)
        f.add_gyro(0.0, 0.0, yaw_bias, now)
        f.add_mag(*mag, now)
    # Gyro-only would have drifted ~25°; the magnetometer holds it near zero.
    assert abs(sensor.heading_change_deg) < 10.0
    assert sensor.has_mag and sensor.has_gyro


def test_fusion_rotation_implies_moving():
    from anumaan.fusion import SensorFusion
    sensor = SensorState()
    f = SensorFusion(sensor)
    grav = (0.0, 0.0, 9.8)
    now = 0.0
    for _ in range(150):                       # sit still ⇒ stationary latches
        now += 0.02
        f.add_accel(*grav, now)
        f.add_gyro(0.0, 0.0, 0.0, now)
    assert sensor.is_stationary is True
    for _ in range(120):                       # rotating, but low linear vibration
        now += 0.02
        f.add_accel(*grav, now)
        f.add_gyro(0.0, 0.0, math.radians(20.0), now)
    assert sensor.is_stationary is False        # fused: turning ⇒ moving


def test_heading_calibration_recovers_offset():
    from anumaan.fusion import HeadingCalibration, _angle_diff
    cal = HeadingCalibration(alpha=0.1, min_samples=20)
    # Truth: driving a straight leg whose compass bearing is 30°, with the phone
    # mounted at a constant +110° offset, so the compass always reads 140°.
    leg_bearing, mount_offset = 30.0, 110.0
    for _ in range(60):
        cal.add(compass_deg=(leg_bearing + mount_offset) % 360, leg_bearing_deg=leg_bearing)
    assert cal.calibrated
    assert abs(_angle_diff(cal.offset, mount_offset)) < 3.0
    # Now anywhere, true heading = compass − offset. A compass of 230° ⇒ ~120°.
    assert abs(_angle_diff(cal.true_heading(230.0), 120.0)) < 3.0


def test_heading_calibration_wraps_around_north():
    from anumaan.fusion import HeadingCalibration, _angle_diff
    cal = HeadingCalibration(alpha=0.1, min_samples=20)
    # leg bearing 350°, offset 20° ⇒ compass 10° (wrapped across north).
    for _ in range(60):
        cal.add(compass_deg=10.0, leg_bearing_deg=350.0)
    assert cal.calibrated and abs(_angle_diff(cal.offset, 20.0)) < 3.0


if __name__ == "__main__":
    import pytest  # noqa: PLC0415

    raise SystemExit(pytest.main([__file__, "-v"]))
