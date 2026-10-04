"""Make a fake recorded walk (same JSONL as logs/) by walking route files one after another.

  python walkgen.py logs/fake_detour.jsonl mock/routes/psb_olin.json mock/routes/olin_flora_rose.json
  python walkgen.py logs/fake_detour.jsonl mock/routes/psb_flora_rose.json:290 mock/routes/flora290_olin.json ...

Use it with simulate.py to test what the server says when someone walks somewhere else.
"""
import argparse
import json
from datetime import datetime, timedelta

import geo


def walk(polylines, speed, stand_s, start_t):
    line = [tuple(p) for poly in polylines for p in poly]
    cum = geo.cumulative_m(line)
    rows, i = [], 0
    while True:
        d = min(cum[-1], max(0.0, (i - stand_s) * speed))
        p = geo.point_at(line, cum, d)
        moving = stand_s <= i and d < cum[-1]
        facing = geo.bearing_deg(p, geo.point_at(line, cum, min(cum[-1], d + 3))) if d < cum[-1] else 0.0
        t = start_t + timedelta(seconds=i)
        rows.append({"t": t.isoformat(), "request": {
            "session_id": "fake", "lat": p[0], "lng": p[1], "accuracy_m": 5,
            "heading_deg": facing, "course_deg": facing if moving else -1, "speed_mps": speed if moving else 0,
            "timestamp": t.isoformat() + "Z", "transcript": None}})
        if d >= cum[-1] and i > stand_s + 5:
            return rows
        i += 1


def load(spec):
    """'route.json' or 'route.json:290' (only the first 290 m of it)."""
    path, _, meters = spec.partition(":")
    poly = json.load(open(path))["polyline"]
    if not meters:
        return poly
    cum = geo.cumulative_m(poly)
    return [p for p, c in zip(poly, cum) if c < float(meters)] + [list(geo.point_at(poly, cum, float(meters)))]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("out")
    p.add_argument("routes", nargs="+", help="route files to walk, in order; route.json:290 = its first 290 m")
    p.add_argument("--speed", type=float, default=1.3)
    p.add_argument("--stand", type=int, default=5, help="seconds standing still at the start")
    args = p.parse_args()
    polylines = [load(spec) for spec in args.routes]
    rows = walk(polylines, args.speed, args.stand, datetime(2026, 10, 3, 18, 0, 0))
    with open(args.out, "w") as f:
        f.writelines(json.dumps(r) + "\n" for r in rows)
    print(f"wrote {args.out}: {len(rows)} ticks")


if __name__ == "__main__":
    main()
