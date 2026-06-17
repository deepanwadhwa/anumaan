"""Sensor fusion: accelerometer + gyroscope + magnetometer.

A single engine that fuses the three IMU sensors into two robust signals on a
shared :class:`SensorState`:

  * **moving vs. stopped** — the accelerometer-variance Schmitt trigger (as before)
    *fused* with gyroscope rotation energy: if you're clearly turning you are
    moving, even when linear vibration is momentarily low.

  * **heading** — a tilt-compensated compass (accelerometer + magnetometer) gives
    an absolute, drift-free reference; the gyroscope provides smooth high-rate
    prediction between magnetometer samples. A complementary filter blends them
    into ``heading_deg`` (absolute) and ``heading_change_deg`` (per leg). With no
    magnetometer it degrades gracefully to gyro-only integration (which drifts).

Why fusion helps turns: the gyroscope alone drifts and its left/right sign
depends on unknown phone mounting; the magnetometer pins the heading to magnetic
north, so the *direction* of a turn becomes meaningful and the *magnitude*
doesn't accumulate error.
"""

from __future__ import annotations

import math
from collections import deque

from .models import SensorState
from .sde import (
    MOVING_HOLD_SECONDS,
    MOVING_THRESHOLD,
    STATIONARY_HOLD_SECONDS,
    STATIONARY_THRESHOLD,
    WINDOW_SAMPLES,
    accel_magnitude,
)

# Sustained yaw rate (deg/s) above which we're definitely moving (turning).
ROTATION_MOVING_DPS = 8.0
# Ignore yaw below this (deg/s) when integrating, so rest noise doesn't drift.
YAW_DEADBAND_DPS = 2.0
# Complementary-filter weight kept on the gyro prediction each magnetometer
# correction (the rest pulls toward the absolute compass).
GYRO_TRUST = 0.92


def _wrap360(a: float) -> float:
    return a % 360.0


def _angle_diff(a: float, b: float) -> float:
    """Signed shortest difference a-b in (-180, 180]."""
    return (a - b + 180.0) % 360.0 - 180.0


def tilt_compensated_heading(accel, mag) -> float:
    """Compass heading (deg, 0=N, clockwise) from gravity + magnetic field.

    Standard tilt compensation (Freescale AN4248). Uses the accelerometer to
    find roll/pitch, de-rotates the magnetometer into the horizontal plane, then
    takes the heading. The absolute zero depends on the device's axis frame (so
    it may carry a constant mounting offset), but heading *changes* track turns.
    """
    ax, ay, az = accel
    mx, my, mz = mag
    roll = math.atan2(ay, az)
    pitch = math.atan2(-ax, math.sqrt(ay * ay + az * az) or 1e-9)
    cr, sr = math.cos(roll), math.sin(roll)
    cp, sp = math.cos(pitch), math.sin(pitch)
    mxh = mx * cp + mz * sp
    myh = mx * sr * sp + my * cr - mz * sr * cp
    return _wrap360(math.degrees(math.atan2(-myh, mxh)))


class SensorFusion:
    """Fuses accel/gyro/mag into is_stationary + heading on a SensorState."""

    def __init__(
        self,
        sensor: SensorState | None = None,
        *,
        window_samples: int = WINDOW_SAMPLES,
        stationary_threshold: float = STATIONARY_THRESHOLD,
        moving_threshold: float = MOVING_THRESHOLD,
        stationary_hold: float = STATIONARY_HOLD_SECONDS,
        moving_hold: float = MOVING_HOLD_SECONDS,
    ) -> None:
        self.sensor = sensor or SensorState()
        self.st_thr = stationary_threshold
        self.mv_thr = moving_threshold
        self.st_hold = stationary_hold
        self.mv_hold = moving_hold
        self._window: deque[float] = deque(maxlen=window_samples)
        self._below_since: float | None = None
        self._above_since: float | None = None
        self._gravity = (0.0, 0.0, 9.8)
        self._yaw_ema = 0.0            # smoothed yaw rate, deg/s (rotation energy)
        self._heading: float | None = None   # fused absolute heading
        self._heading_ref: float | None = None  # heading at the leg start
        self._last_gyro_t: float | None = None

    # ----- accelerometer: gravity + moving/stopped ----------------------
    def add_accel(self, x: float, y: float, z: float, now: float) -> SensorState:
        self._gravity = (x, y, z)
        self.sensor.raw_accel = (x, y, z)
        self._window.append(accel_magnitude(x, y, z))
        var = self._variance()
        self.sensor.accel_variance = var

        self._below_since = (self._below_since if var < self.st_thr and self._below_since is not None
                             else (now if var < self.st_thr else None))
        self._above_since = (self._above_since if var > self.mv_thr and self._above_since is not None
                             else (now if var > self.mv_thr else None))
        rotating = abs(self._yaw_ema) > ROTATION_MOVING_DPS  # fused rotation cue

        if self.sensor.is_stationary:
            moved = self._above_since is not None and now - self._above_since >= self.mv_hold
            if moved or rotating:
                self.sensor.is_stationary = False
        else:
            still = self._below_since is not None and now - self._below_since >= self.st_hold
            if still and not rotating:
                self.sensor.is_stationary = True
        return self.sensor

    def _variance(self) -> float:
        n = len(self._window)
        if n < 2:
            return 0.0
        m = sum(self._window) / n
        return sum((v - m) ** 2 for v in self._window) / n

    # ----- gyroscope: yaw rate + heading prediction ---------------------
    def add_gyro(self, x: float, y: float, z: float, now: float) -> SensorState:
        self.sensor.raw_gyro = (x, y, z)
        self.sensor.has_gyro = True
        g = self._gravity
        gm = math.sqrt(g[0] ** 2 + g[1] ** 2 + g[2] ** 2)
        yaw_dps = 0.0
        if gm > 1e-6:
            yaw_dps = math.degrees((x * g[0] + y * g[1] + z * g[2]) / gm)
        self._yaw_ema = 0.8 * self._yaw_ema + 0.2 * yaw_dps
        self.sensor.yaw_rate_dps = round(self._yaw_ema, 2)

        if self._heading is None:
            self._heading = 0.0       # gyro-only relative start (mag will anchor)
        if self._last_gyro_t is not None and abs(yaw_dps) >= YAW_DEADBAND_DPS:
            dt = now - self._last_gyro_t
            if 0 < dt < 1.0:
                self._heading = _wrap360(self._heading + yaw_dps * dt)
        self._last_gyro_t = now
        self._emit()
        return self.sensor

    # ----- magnetometer: absolute compass correction --------------------
    def add_mag(self, x: float, y: float, z: float, now: float) -> SensorState:
        self.sensor.raw_mag = (x, y, z)
        self.sensor.has_mag = True
        compass = tilt_compensated_heading(self._gravity, (x, y, z))
        if self._heading is None:
            self._heading = compass
        else:
            self._heading = _wrap360(self._heading
                                     + (1 - GYRO_TRUST) * _angle_diff(compass, self._heading))
        self.sensor.heading_deg = round(self._heading, 1)
        self._emit()
        return self.sensor

    def _emit(self) -> None:
        if self._heading is None:
            return
        if self._heading_ref is None:
            self._heading_ref = self._heading
        self.sensor.heading_change_deg = _angle_diff(self._heading, self._heading_ref)
        self.sensor.heading_deg = round(self._heading, 1)

    # ----- per-leg reset ------------------------------------------------
    def reset_leg(self) -> None:
        """Reset the moving/stopped window and re-baseline the heading change."""
        self._window.clear()
        self._below_since = None
        self._above_since = None
        self.sensor.is_stationary = False
        self.sensor.accel_variance = 0.0
        self._heading_ref = self._heading   # new baseline = current heading
        self.sensor.heading_change_deg = 0.0


class HeadingCalibration:
    """Recover the phone's constant heading offset with no user interaction.

    On a known **straight** leg, the vehicle's true bearing equals the leg's
    compass bearing (from the route). The phone's tilt-compensated compass reads
    that bearing plus a fixed mounting/magnetic offset. So while driving straight
    and not turning we sample ``offset = compass − leg_bearing`` and average it
    (a circular EMA, robust to the 0/360 wrap). Once converged, the true vehicle
    heading anywhere is ``compass − offset`` — which lets us tell a *wrong* turn
    from a missing one.
    """

    def __init__(self, alpha: float = 0.03, min_samples: int = 40) -> None:
        self.alpha = alpha
        self.min_samples = min_samples
        self._s = 0.0
        self._c = 0.0
        self.n = 0

    def add(self, compass_deg: float, leg_bearing_deg: float) -> None:
        o = math.radians(_wrap360(compass_deg - leg_bearing_deg))
        a = self.alpha
        self._s = (1 - a) * self._s + a * math.sin(o)
        self._c = (1 - a) * self._c + a * math.cos(o)
        self.n += 1

    @property
    def calibrated(self) -> bool:
        return self.n >= self.min_samples and (self._s ** 2 + self._c ** 2) > 1e-6

    @property
    def offset(self) -> float:
        return _wrap360(math.degrees(math.atan2(self._s, self._c)))

    def true_heading(self, compass_deg: float) -> float:
        return _wrap360(compass_deg - self.offset)
