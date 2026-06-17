"""Core data structures for the navigation state machine.

These mirror the architecture defined in spec.xml:
  * ``Milestone``   — an immutable physical node on the route.
  * ``NavState``    — the mutable global singleton tracking movement.
  * ``SensorState`` — the singleton tracking IMU stationary detection (SDE).
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class Milestone:
    """A physical node on the route (a stop sign, intersection, etc.).

    Per spec.xml the required fields are ``id``, ``type`` and
    ``distance_from_prior``; ``name`` and ``target_speed_limit`` are retained as
    convenient (optional) extras used by the UI and the detour graph.

    Attributes:
        id: Underlying map node ID.
        type: Node category, e.g. ``"stop_sign"`` or ``"traffic_light"``.
        distance_from_prior: Meters from the previous milestone on the route.
            For the first milestone (the origin) this is ``0.0``.
        name: Human-readable label spoken/shown to the driver.
        target_speed_limit: Posted speed limit for the leg, in meters/second.
    """

    id: str
    type: str
    distance_from_prior: float
    name: str = ""
    target_speed_limit: float = 11.0

    def __post_init__(self) -> None:
        if self.distance_from_prior < 0:
            raise ValueError("distance_from_prior must be non-negative")
        if self.target_speed_limit <= 0:
            raise ValueError("target_speed_limit must be positive")


@dataclass
class NavState:
    """Global singleton tracking movement through the milestone array.

    Attributes:
        current_milestone_index: Pointer into the active route array. Index 0 is
            the origin; the driver is always travelling *toward* this index.
        estimated_speed: Current system speed estimate, in meters/second. This is
            the value continuously recalibrated by driver feedback.
        time_entered_leg: Epoch timestamp (seconds) marking when the current leg
            began. Used to measure the actual travel time of a leg.
        accumulated_distance: Meters travelled on the current leg under dead
            reckoning since ``time_entered_leg``.
    """

    current_milestone_index: int = 0
    estimated_speed: float = 11.0  # ~25 mph, a sane urban default
    time_entered_leg: float = 0.0
    accumulated_distance: float = 0.0

    # Rolling history of confirmed leg velocities, kept for diagnostics/UI.
    velocity_history: list[float] = field(default_factory=list)


@dataclass
class SensorState:
    """Singleton tracking remote IMU telemetry and the SDE verdict.

    Telemetry arrives over the network (see :mod:`anumaan.bridge`) — the laptop has
    no physical IMU — so this state is written by the sensor-ingestion layer and
    read by the navigation state machine.

    Attributes:
        raw_accel: Latest ``(x, y, z)`` acceleration vector, in g, as received
            from the remote device.
        accel_variance: Rolling ~1.5 s population variance of the acceleration
            vector magnitude, in g. Low when the vehicle is still.
        is_stationary: Binary trigger — ``True`` once the variance has stayed
            below the stationary threshold long enough (see :mod:`anumaan.sde`).
            Per spec, the IMU is used *only* for this binary flag, never for
            continuous speed integration (which would drift).
        packets: Count of telemetry packets ingested (diagnostics).
    """

    raw_accel: tuple[float, float, float] = (0.0, 0.0, 0.0)
    accel_variance: float = 0.0
    is_stationary: bool = False
    packets: int = 0
    last_update: float = 0.0   # clock() time of the most recent sample

    # Orientation fusion (gyroscope + magnetometer). ``heading_deg`` is the
    # fused absolute compass heading (0=N, drift-free when a magnetometer is
    # present); ``heading_change_deg`` is the signed heading change since the
    # current leg began (positive = right / clockwise).
    raw_gyro: tuple[float, float, float] = (0.0, 0.0, 0.0)
    raw_mag: tuple[float, float, float] = (0.0, 0.0, 0.0)
    heading_deg: float = 0.0
    heading_change_deg: float = 0.0
    yaw_rate_dps: float = 0.0   # smoothed yaw rate (deg/s); ~0 ⇒ driving straight
    has_gyro: bool = False
    has_mag: bool = False
