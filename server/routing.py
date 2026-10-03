"""Find places and walking routes
ROUTING_MOCK=1, reads mock/demo_route.json"""
import json
import os
from pathlib import Path

import geo

MOCK = os.getenv("ROUTING_MOCK", "1") == "1"
MOCK_FILE = Path(os.getenv("ROUTING_MOCK_FILE") or Path(__file__).parent / "mock" / "demo_route.json")

def _load_mock():
    with MOCK_FILE.open() as f:
        return json.load(f)


def find_place(text, near):
    """Spoken destination -> {"name", "lat", "lng"}, or None if nothing matches."""
    if MOCK:
        return _load_mock()["destination"]
    raise NotImplementedError("real place search comes in step 6")

def get_route(start, dest):
    """Walking route from start (lat, lng) to dest (a find_place result)."""
    if MOCK:
        return prepare(_load_mock())
    raise NotImplementedError("real routing comes in step 6")


def prepare(route):
    """Add what route tracking needs: cumulative distances, and each step's distance along the route.
    Steps are located in order, each searching forward from the previous one,
    so a route that passes the same corner twice still gets the right order."""
    poly, cum = route["polyline"], geo.cumulative_m(route["polyline"])
    route["cum"] = cum
    route["distance_m"] = cum[-1]
    lo = 0.0
    for step in route["steps"]:
        along, _, _ = geo.locate((step["lat"], step["lng"]), poly, cum, lo)
        step["along_m"] = along
        lo = along
    return route