"""Bundle real recorded walks, replayed through today's server logic, as demo past trips in the iOS app.

  python make_demo_trips.py      ->  ios/AcousticMaps/AcousticMaps/DemoTrips.json

Each trip has the route, the walked path (one fix a second) and what the server said when.
"""
import json
import os
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).parent
OUT = HERE.parent / "ios" / "AcousticMaps" / "AcousticMaps" / "DemoTrips.json"

# (log, route file, what was said, tick it was said at, title, note)
WALKS = [
    ("AD19A946", "psb_malott.json", "take me to Malott", 15, "Malott Hall", "Clean walk from PSB"),
    ("00BA1CE9", "psb_malott.json", "take me to Malott", 20, "Malott Hall", "Wrong turn, guided back"),
    ("9C6CC66D", "psb_malott.json", "take me to Malott", 15, "Malott Hall", "Missed a turn, guided back"),
    ("6B0A0F06", "malott_psb.json", "take me to PSB", 15, "Physical Sciences Building", "Malott back to PSB"),
]


def trip(log_id, route_file, say, at, title, note):
    os.environ["ROUTING_MOCK"] = "1"
    os.environ["ROUTING_MOCK_FILE"] = str(HERE / "mock" / "routes" / route_file)
    import importlib

    import guidance
    import handler
    import routing
    import sessions
    import simulate
    importlib.reload(routing)          # pick up the route file for this walk
    importlib.reload(guidance)
    importlib.reload(handler)
    sessions._sessions.clear()
    log = next((HERE / "logs").glob(f"{log_id}*.jsonl"))
    ticks, routes = simulate.simulate(log, say, at)
    route = routes[0]["route"]
    start = next(i for i, t in enumerate(ticks) if t["heard"])
    end = next((i for i, t in enumerate(ticks) if t["state"] == "arrived"), len(ticks) - 1)
    walk = ticks[start:end + 1]
    t0 = walk[0]["t"]
    first = json.loads(log.read_text().splitlines()[0])["t"]
    return {
        "id": log_id,
        "destination": title,
        "note": note,
        "date": datetime.fromisoformat(first).strftime("%Y-%m-%dT%H:%M:%S"),
        "duration_s": round(walk[-1]["t"] - t0),
        "distance_m": round(route["distance_m"]),
        "arrived": walk[-1]["state"] == "arrived",
        "route_line": [[round(a, 6), round(b, 6)] for a, b in route["polyline"]],
        "turns": [{"lat": st["lat"], "lng": st["lng"], "turn": st["turn"],
                   "instruction": guidance.turn_phrase(st)} for st in route["steps"]],
        "ticks": [{"t": round(t["t"] - t0, 1), "lat": round(t["lat"], 6), "lng": round(t["lng"], 6),
                   "state": t["state"], **({"say": t["say"]} if t["say"] else {}),
                   **({"haptic": t["haptic"]} if t["haptic"] else {})} for t in walk],
    }


if __name__ == "__main__":
    trips = [trip(*w) for w in WALKS]
    OUT.write_text(json.dumps({"trips": trips}, separators=(",", ":")))
    for t in trips:
        said = sum(1 for x in t["ticks"] if "say" in x)
        print(f"{t['destination']:28} {t['note']:30} {t['duration_s']:4d} s  {len(t['ticks'])} ticks  "
              f"{said} lines  arrived={t['arrived']}")
    print(f"wrote {OUT} ({OUT.stat().st_size // 1024} KB)")
