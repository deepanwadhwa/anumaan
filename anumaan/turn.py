"""Turn Detection Engine (TDE) — gyroscope-based heading change.

The accelerometer SDE answers "are we moving?"; the gyroscope answers "are we
turning, and which way?". Together with the route's expected turn at each node,
this lets the system *confirm* you took the right turn (auto-advancing the node)
or ask "did you turn yet?" when an expected turn hasn't been sensed.

Approach (a small complementary filter, no external libs):
  * The phone's orientation in the car is unknown, so we can't read yaw off one
    gyro axis directly. Instead we project the angular-velocity vector onto the
    gravity (vertical) direction — estimated from the accelerometer — to get the
    yaw rate about the vertical axis:  ω_yaw = gyro · ĝ.
  * Integrating ω_yaw over time gives the heading change. We only integrate to
    detect a *discrete* turn over a few seconds, where gyro drift is negligible
    (unlike position dead reckoning, which drifts badly).

Units: gyro in rad/s, gravity from the accelerometer in any consistent unit
(only its direction is used). ``heading_change_deg`` is signed degrees since the
last :meth:`reset` (i.e. since the current leg began).
"""

from __future__ import annotations

import math

from .models import SensorState

# Below this angular rate (deg/s) we treat the vehicle as not turning, so sensor
# noise at rest doesn't slowly accumulate a phantom heading drift.
YAW_RATE_DEADBAND_DPS = 3.0


class TurnDetector:
    """Integrates yaw rate into a per-leg heading change on a :class:`SensorState`."""

    def __init__(self, sensor: SensorState | None = None) -> None:
        self.sensor = sensor or SensorState()
        self._last_t: float | None = None
        self._heading = 0.0  # signed degrees since reset

    def add_gyro(self, gx: float, gy: float, gz: float,
                 gravity: tuple[float, float, float], now: float) -> SensorState:
        """Fold one gyroscope sample (rad/s) using the latest gravity direction."""
        self.sensor.raw_gyro = (gx, gy, gz)
        self.sensor.has_gyro = True
        gmag = math.sqrt(gravity[0] ** 2 + gravity[1] ** 2 + gravity[2] ** 2)
        if gmag < 1e-6:
            self._last_t = now
            return self.sensor
        # Yaw rate about the vertical (gravity) axis, rad/s → deg/s.
        gu = (gravity[0] / gmag, gravity[1] / gmag, gravity[2] / gmag)
        yaw_rate_dps = math.degrees(gx * gu[0] + gy * gu[1] + gz * gu[2])

        if self._last_t is not None:
            dt = now - self._last_t
            if 0 < dt < 1.0 and abs(yaw_rate_dps) >= YAW_RATE_DEADBAND_DPS:
                self._heading += yaw_rate_dps * dt
        self._last_t = now
        self.sensor.heading_change_deg = self._heading
        return self.sensor

    def reset(self) -> None:
        """Zero the accumulated heading (call at the start of each leg)."""
        self._heading = 0.0
        self._last_t = None
        self.sensor.heading_change_deg = 0.0


# --------------------------------------------------------------------------
# Route geometry → expected turn at each node
# --------------------------------------------------------------------------
def bearing(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Initial compass bearing (degrees, 0=N, clockwise) from point a to b."""
    lat1, lat2 = math.radians(a[0]), math.radians(b[0])
    dlon = math.radians(b[1] - a[1])
    y = math.sin(dlon) * math.cos(lat2)
    x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dlon)
    return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0


def turn_angle(prev: tuple[float, float], node: tuple[float, float],
               nxt: tuple[float, float]) -> float:
    """Signed turn at ``node`` in degrees, (-180, 180]. Positive = right (CW)."""
    delta = bearing(node, nxt) - bearing(prev, node)
    delta = (delta + 180.0) % 360.0 - 180.0
    return delta


# A turn smaller than this is "continue straight"; at/above it we expect a turn.
TURN_SIGNIFICANT_DEG = 30.0


def classify_turn(angle: float) -> str:
    """Human label for a signed turn angle."""
    a = abs(angle)
    if a < TURN_SIGNIFICANT_DEG:
        return "straight"
    side = "right" if angle > 0 else "left"
    if a >= 150:
        return f"sharp {side} (U-turn)"
    if a >= 100:
        return f"sharp {side}"
    if a >= 55:
        return side
    return f"slight {side}"
