"""Human-Vector Offline Navigation System (Anumaan) — navigation core.

A zero-GPS, fully offline navigation state machine. Time-based dead reckoning
predicts arrival at each milestone; the phone's accelerometer (streamed in over
the UDP :mod:`~anumaan.bridge`) drives the Stationary Detection Engine
(:mod:`~anumaan.sde`), which auto-snaps to a node when the vehicle stops within
range and recalibrates the global speed estimate.
"""

from .models import Milestone, NavState, SensorState
from .state_machine import NavigationEngine, NavEvent, EventKind, Prompt
from .sde import StationaryDetector, MockAccelerometer
from .bridge import SensorBridge, UdpSensorSender, parse_accel

__all__ = [
    "Milestone",
    "NavState",
    "SensorState",
    "NavigationEngine",
    "NavEvent",
    "EventKind",
    "Prompt",
    "StationaryDetector",
    "MockAccelerometer",
    "SensorBridge",
    "UdpSensorSender",
    "parse_accel",
]

__version__ = "1.0.0"
