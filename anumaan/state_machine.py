"""The deterministic navigation state machine.

Implements the spec.xml business rules that belong to the *core state machine*
(sensor ingestion lives in :mod:`anumaan.bridge`, the SDE math in :mod:`anumaan.sde`):

  Rule 1 — Dead reckoning:  T_exp = distance_from_prior / estimated_speed
  Rule 3 — Auto-snap (SDE): when ``SensorState.is_stationary`` is set AND dead
                            reckoning places us within 50 m of the next
                            milestone, automatically fire the arrival handler
                            and log "NODE SNAPPED".
  Rule 4 — Speed smoothing: estimated_speed = estimated_speed*0.7 + V_true*0.3

A convenience fallback prompt is also surfaced when the expected time elapses
without a stationary reading, so navigation can report "overdue" while it waits
for the driver to actually stop.

The engine owns no wall-clock of its own: every method that needs "the current
time" takes an explicit ``now`` epoch timestamp. This keeps the machine strictly
deterministic and trivially testable — the bridge/simulator injects time from
outside.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

from .models import Milestone, NavState, SensorState

# Rule 4 smoothing weights.
SMOOTHING_RETAIN = 0.7  # weight kept on the prior estimate
SMOOTHING_OBSERVE = 0.3  # weight given to the freshly observed velocity

# Rule 3: how close (meters) dead reckoning must place us to a milestone for a
# stationary reading to count as an arrival.
SNAP_RANGE_M = 50.0

# Sanity bounds so a near-instant snap (tiny T_actual) can't explode the speed
# estimate, and so the estimate stays in a plausible driving range.
MIN_LEG_SECONDS = 3.0          # a leg must take at least this long to auto-snap
SPEED_MIN = 1.0                # m/s
SPEED_MAX = 45.0               # m/s (~100 mph)


class EventKind(Enum):
    AUTO_SNAP = "auto_snap"          # SDE auto-confirmed arrival (no human needed)
    FALLBACK_PROMPT = "fallback"     # rule 4: ask the human to confirm
    DESTINATION = "destination"      # the milestone just handled was the last one


@dataclass
class NavEvent:
    """Something the loop must react to: an auto-snap, or a fallback prompt."""

    kind: EventKind
    milestone: Milestone
    expected_time: float           # T_exp for the leg, seconds
    elapsed_time: float            # actual seconds elapsed on the leg so far
    message: str
    automated: bool = False        # True when the SDE handled it with no prompt
    v_true: float | None = None    # observed leg velocity, set on auto-snap


# Backwards-compatible alias: a fallback prompt is still a "Prompt".
Prompt = NavEvent


class NavigationEngine:
    """Drives a vehicle through a sequential ``Milestone`` array.

    The engine advances under time-based dead reckoning. When the accumulated
    dead-reckoned distance reaches the next milestone's ``distance_from_prior``,
    it raises a :class:`Prompt` asking the human to confirm arrival.
    """

    def __init__(
        self,
        route: list[Milestone],
        state: NavState | None = None,
        sensor: SensorState | None = None,
        start_time: float = 0.0,
    ) -> None:
        if len(route) < 2:
            raise ValueError("route needs at least an origin and one milestone")
        self.route: list[Milestone] = list(route)
        self.state = state or NavState()
        # Shared with the SDE: the StationaryDetector writes is_stationary here.
        self.sensor = sensor or SensorState()
        # We begin parked at index 0 (origin) heading toward index 1.
        self.state.current_milestone_index = 1
        self.state.time_entered_leg = start_time
        self.state.accumulated_distance = 0.0
        self._last_tick_time = start_time

    # ----- introspection ------------------------------------------------
    @property
    def next_milestone(self) -> Milestone:
        return self.route[self.state.current_milestone_index]

    @property
    def is_complete(self) -> bool:
        return self.state.current_milestone_index >= len(self.route)

    def expected_time(self) -> float:
        """Rule 1: expected seconds to reach the next milestone."""
        return self.next_milestone.distance_from_prior / self.state.estimated_speed

    def remaining_distance(self) -> float:
        """Meters of dead-reckoned distance left on the current leg."""
        return max(
            0.0,
            self.next_milestone.distance_from_prior - self.state.accumulated_distance,
        )

    def within_snap_range(self) -> bool:
        """True when dead reckoning places us within ``SNAP_RANGE_M`` of the node.

        Used by the SDE rule: a stationary reading only counts as an arrival when
        we're near the expected milestone, i.e. the dead-reckoned distance has
        come within 50 m *before* the node, or anywhere past it. The one-sided
        check matters for live telemetry, where dead reckoning can run ahead of
        the vehicle before it actually stops — a genuine stop must still snap.
        """
        remaining = (
            self.next_milestone.distance_from_prior - self.state.accumulated_distance
        )
        return remaining <= SNAP_RANGE_M

    # ----- core loop ----------------------------------------------------
    def tick(self, now: float, is_stationary: bool | None = None,
             is_moving: bool | None = None) -> NavEvent | None:
        """Advance dead reckoning to time ``now`` and check for an arrival.

        Two independent binary signals drive the loop:

          * ``is_moving`` — whether to advance the dead-reckoned position. Defaults
            to ``not is_stationary``. The caller sets this False when there is no
            fresh telemetry, so the car holds position instead of driving itself.
          * ``is_stationary`` — a *genuine* SDE stop (only set True from real
            telemetry). This is what arms an auto-snap; "no telemetry" must NOT
            count as stationary, or it would snap a milestone you never reached.

        Arrival is resolved in priority order:

          1. **Auto-snap (SDE):** genuinely stationary, within 50 m of the next
             milestone, and the leg has lasted at least ``MIN_LEG_SECONDS`` →
             ``AUTO_SNAP``. The minimum-leg guard stops a fresh/short leg from
             snapping instantly with a near-zero travel time.
          2. **Fallback:** otherwise, if the dead-reckoned distance has reached
             the milestone, return a ``FALLBACK_PROMPT``.
        """
        if self.is_complete:
            return None
        dt = now - self._last_tick_time
        if dt < 0:
            raise ValueError("time moved backwards")
        self._last_tick_time = now

        stationary = self.sensor.is_stationary if is_stationary is None else is_stationary
        moving = (not stationary) if is_moving is None else is_moving

        # Motion gate: only advance the dead-reckoned position while moving.
        if moving:
            self.state.accumulated_distance += self.state.estimated_speed * dt
        # Hard milestone gate: never dead-reckon PAST the next node. The car holds
        # at the node until arrival is confirmed (a stop auto-snap, a detected
        # turn, or the manual "I've arrived" button). It never glides through.
        self.state.accumulated_distance = min(
            self.state.accumulated_distance, self.next_milestone.distance_from_prior)

        # Rule 2: automated stationary snap — only on a genuine stop, within
        # range, after the leg has actually been under way for a moment.
        leg_elapsed = now - self.state.time_entered_leg
        if stationary and self.within_snap_range() and leg_elapsed >= MIN_LEG_SECONDS:
            ms = self.next_milestone
            elapsed = now - self.state.time_entered_leg
            was_last = self.state.current_milestone_index == len(self.route) - 1
            v_true = self._arrive(now)
            return NavEvent(
                kind=EventKind.DESTINATION if was_last else EventKind.AUTO_SNAP,
                milestone=ms,
                expected_time=ms.distance_from_prior / max(self.state.estimated_speed, 1e-9),
                elapsed_time=elapsed,
                message=f"SDE auto-snapped arrival at {ms.name or ms.id} ({ms.type}).",
                automated=True,
                v_true=v_true,
            )

        # Rule 4: human fallback once the dead-reckoned distance is reached.
        if self.state.accumulated_distance >= self.next_milestone.distance_from_prior:
            return self._build_prompt(now)
        return None

    def _build_prompt(self, now: float) -> NavEvent:
        ms = self.next_milestone
        elapsed = now - self.state.time_entered_leg
        is_last = self.state.current_milestone_index == len(self.route) - 1
        landmark = ms.name or ms.id
        message = (
            f"Have you reached {landmark} ({ms.type})? [YES / NO]"
        )
        return NavEvent(
            kind=EventKind.DESTINATION if is_last else EventKind.FALLBACK_PROMPT,
            milestone=ms,
            expected_time=self.expected_time(),
            elapsed_time=elapsed,
            message=message,
        )

    # ----- arrival handling --------------------------------------------
    def _arrive(self, now: float) -> float:
        """Shared arrival handler for both manual and automated triggers.

        Computes the true leg velocity V_true = distance / T_actual, blends it
        into ``estimated_speed`` with the 70/30 weighting (Rule 3), advances the
        milestone pointer, and resets the leg accumulators. Returns ``V_true``.
        """
        ms = self.next_milestone
        # Clamp the elapsed time so a snap that fires very soon after the leg
        # began can't divide by ~0 and produce an absurd velocity.
        t_actual = max(now - self.state.time_entered_leg, MIN_LEG_SECONDS)
        v_true = ms.distance_from_prior / t_actual

        blended = (
            self.state.estimated_speed * SMOOTHING_RETAIN + v_true * SMOOTHING_OBSERVE
        )
        self.state.estimated_speed = min(SPEED_MAX, max(SPEED_MIN, blended))
        self.state.velocity_history.append(v_true)

        # Advance to the next leg.
        self.state.current_milestone_index += 1
        self.state.time_entered_leg = now
        self.state.accumulated_distance = 0.0
        self._last_tick_time = now
        return v_true

    def confirm_arrival(self, now: float) -> float:
        """Handle a manual ``YES / ARRIVED NOW`` (Rule 4 fallback path)."""
        if self.is_complete:
            raise RuntimeError("route already complete")
        return self._arrive(now)

    def deny_arrival(self, now: float) -> None:
        """Handle ``NO / NOT YET``.

        The driver says they haven't reached the milestone yet. We keep the leg
        timer running and pin the dead-reckoned distance just shy of the
        milestone so the engine doesn't re-fire immediately on the next tick but
        will prompt again as more real time elapses.
        """
        if self.is_complete:
            return
        # Hold one estimated-second short of the milestone so repeated ticks at
        # the same instant don't spam prompts, while genuine elapsed time still
        # pushes us back over the threshold.
        threshold = self.next_milestone.distance_from_prior
        self.state.accumulated_distance = max(
            0.0, threshold - self.state.estimated_speed
        )
        self._last_tick_time = now
