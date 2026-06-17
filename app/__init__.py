"""Anumaan local web application.

Wraps the offline navigation engine (the :mod:`anumaan` package) in a real,
locally-hosted app: download OpenStreetMap data for an area (road graph + offline
map tiles), set a home location, pick a start/destination, and run the zero-GPS
dead-reckoning + IMU navigation along the real route.
"""
