"""Stationary Detection Engine (SDE) — spec.xml business rule 2.

The SDE consumes a stream of accelerometer samples (x, y, z in *g*) and decides,
purely from a rolling-window variance, whether the device is currently
stationary. This is the mechanism that lets Anumaan auto-snap to a milestone when
the vehicle stops — minimizing manual driver prompts.

Per the spec's hard boundary, accelerometer data is **never integrated into a
continuous speed estimate** (that drifts). It is used only for a *binary*
stationary/moving decision.

Algorithm:
  * Poll the accelerometer at 50 Hz.
  * Maintain a rolling 1.5 s window (75 samples) of acceleration-vector
    magnitudes ``sqrt(x^2 + y^2 + z^2)``.
  * Compute the population variance of the window each sample → ``accel_variance``.
  * If ``accel_variance`` stays below ``STATIONARY_THRESHOLD`` (0.02 g) for more
    than ``STATIONARY_HOLD_SECONDS`` (1 s), set ``is_stationary = True``;
    otherwise clear it.
"""

from __future__ import annotations

import math
import random
from collections import deque

from .models import SensorState

# --- tunables -------------------------------------------------------------
SAMPLE_RATE_HZ = 50
WINDOW_SECONDS = 1.5
WINDOW_SAMPLES = round(SAMPLE_RATE_HZ * WINDOW_SECONDS)  # 75

# Hysteresis (a Schmitt trigger) so the verdict doesn't flap and a brief jiggle
# can't kick the car into motion:
#   * to go MOVING, variance must exceed MOVING_THRESHOLD for MOVING_HOLD_SECONDS;
#   * to go STATIONARY, variance must stay under STATIONARY_THRESHOLD for
#     STATIONARY_HOLD_SECONDS.
# The gap between the two thresholds prevents chatter around the boundary.
STATIONARY_THRESHOLD = 0.015   # g² — below this (held) ⇒ stopped
MOVING_THRESHOLD = 0.040       # g² — above this (held) ⇒ moving
STATIONARY_HOLD_SECONDS = 1.0
MOVING_HOLD_SECONDS = 0.8


def accel_magnitude(x: float, y: float, z: float) -> float:
    """Magnitude of the acceleration vector, ``sqrt(x^2 + y^2 + z^2)``."""
    return math.sqrt(x * x + y * y + z * z)


class StationaryDetector:
    """Hysteretic rolling-variance motion detector writing into a SensorState.

    Feed it samples with :meth:`add_sample`; read the verdict off the shared
    ``SensorState`` (``accel_variance`` / ``is_stationary``). Starts in the
    "moving/unknown" state and only latches stationary after sustained stillness.
    """

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
        self.stationary_threshold = stationary_threshold
        self.moving_threshold = moving_threshold
        self.stationary_hold = stationary_hold
        self.moving_hold = moving_hold
        self._window: deque[float] = deque(maxlen=window_samples)
        self._below_since: float | None = None   # variance under stationary thr.
        self._above_since: float | None = None    # variance over moving thr.

    def add_sample(self, x: float, y: float, z: float, now: float) -> SensorState:
        """Ingest one accelerometer sample taken at epoch ``now`` (seconds)."""
        self._window.append(accel_magnitude(x, y, z))
        variance = self._variance()
        self.sensor.accel_variance = variance

        # Track how long we've been clearly-still / clearly-moving.
        self._below_since = (self._below_since if variance < self.stationary_threshold
                             and self._below_since is not None else
                             (now if variance < self.stationary_threshold else None))
        self._above_since = (self._above_since if variance > self.moving_threshold
                             and self._above_since is not None else
                             (now if variance > self.moving_threshold else None))

        if self.sensor.is_stationary:
            # Only leave "stationary" after sustained motion.
            if self._above_since is not None and now - self._above_since >= self.moving_hold:
                self.sensor.is_stationary = False
        else:
            # Only enter "stationary" after sustained stillness.
            if self._below_since is not None and now - self._below_since >= self.stationary_hold:
                self.sensor.is_stationary = True
        return self.sensor

    def reset(self) -> None:
        """Clear the window and verdict (e.g. after an arrival/leg change)."""
        self._window.clear()
        self._below_since = None
        self._above_since = None
        self.sensor.is_stationary = False
        self.sensor.accel_variance = 0.0

    def _variance(self) -> float:
        n = len(self._window)
        if n < 2:
            return 0.0
        mean = sum(self._window) / n
        return sum((m - mean) ** 2 for m in self._window) / n


class MockAccelerometer:
    """Deterministic simulated IMU feed (spec implementation step 2).

    Emits Gaussian-noisy samples around 1 g of gravity. When ``moving`` the noise
    is large (road vibration, engine, steering) and drives the variance above the
    threshold; when stopped the feed "flatlines" with only faint sensor noise, so
    the variance collapses below the threshold.
    """

    def __init__(self, seed: int = 0,
                 moving_noise: float = 0.30, idle_noise: float = 0.002) -> None:
        self._rng = random.Random(seed)
        self.moving_noise = moving_noise
        self.idle_noise = idle_noise

    def sample(self, moving: bool) -> tuple[float, float, float]:
        sigma = self.moving_noise if moving else self.idle_noise
        gx = self._rng.gauss(0.0, sigma)
        gy = self._rng.gauss(0.0, sigma)
        gz = 1.0 + self._rng.gauss(0.0, sigma)  # gravity on the z-axis
        return gx, gy, gz
