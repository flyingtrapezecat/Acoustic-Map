"""Replay a recorded walk through the server logic (no HTTP) and write an animated map of what it said.

  python simulate.py logs/<walk>.jsonl --route mock/routes/psb_malott.json --say "take me to Malott" --at 15 --open
"""
import argparse
import json
import os
import webbrowser
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).parent
OFF_M = 20       # further than this from the route = off route
BACK_M = 8       # this far behind progress while moving = walking the wrong way
MIN_TICKS = 3    # an issue must last this many ticks to be listed


def simulate(log_path, say, at):
    import guidance
    import handler
    import sessions
    from models import UpdateRequest

    clock = [0.0]
    handler.time.monotonic = guidance.time.monotonic = lambda: clock[0]

    rows = [json.loads(line) for line in open(log_path) if line.strip()]
    t0 = datetime.fromisoformat(rows[0]["t"])
    ticks, last_ts = [], None
    for i, row in enumerate(rows):
        clock[0] = (datetime.fromisoformat(row["t"]) - t0).total_seconds()
        transcript = say if i == at else None
        req = UpdateRequest(**dict(row["request"], session_id="sim", transcript=transcript))
        resp = handler.handle_update(req, transcript)
        s = sessions.get("sim")
        q = row["request"]
        tick = {"i": i, "t": round(clock[0], 1), "clock": row["t"][11:19],
                "lat": q["lat"], "lng": q["lng"], "acc": round(q["accuracy_m"] or 0, 1),
                "speed": q["speed_mps"], "stale": q["timestamp"] == last_ts,
                "heard": transcript, "say": resp.say, "haptic": resp.haptic, "state": resp.state,
                "status": "idle"}
        last_ts = q["timestamp"]
        if s["route"]:
            step = s["route"]["steps"][s["step_i"]]
            tick.update(progress=round(s["progress_m"], 1), raw=round(s["raw_along_m"], 1),
                        off=round(s["off_m"], 1), step=s["step_i"],
                        to_turn=round(step["along_m"] - s["progress_m"], 1), status=status(s, q))
        ticks.append(tick)
    return ticks, s["route"]


def status(s, q):
    if s["state"] == "arrived":
        return "arrived"
    if s["off_m"] > OFF_M:
        return "off"
    if (q["speed_mps"] or 0) > 0.5 and s["raw_along_m"] < s["progress_m"] - BACK_M:
        return "back"
    return "ok"


def find_issues(ticks, route):
    issues, run = [], []
    for tick in ticks + [{"status": "end"}]:
        if run and tick["status"] != run[0]["status"]:
            if len(run) >= MIN_TICKS:
                issues.append(describe(run, ticks, route))
            run = []
        if tick["status"] in ("off", "back"):
            run.append(tick)
    return issues


def describe(run, ticks, route):
    first, last = run[0], run[-1]
    gaps = [abs(st["along_m"] - first["progress"]) for st in route["steps"][:-1]]
    turn_no = gaps.index(min(gaps)) + 1 if gaps else 0
    if first["status"] == "off":
        what = (f"Left the route at turn {turn_no}" if gaps and min(gaps) <= 15 else "Went off route") + \
               f" · up to {max(t['off'] for t in run):.0f} m away"
    else:
        what = "Walked the wrong way"
    spoken = [t["say"] for t in ticks[first["i"]:last["i"] + 1] if t["say"]]
    return {"kind": first["status"], "from": first["i"], "to": last["i"],
            "title": f"{first['clock']} · {what} · {last['t'] - first['t']:.0f} s",
            "server": spoken[0] if spoken else None}


def write_html(ticks, route, issues, out, title):
    data = {"title": title, "route": route["polyline"], "cum": route["cum"],
            "turns": [[st["lat"], st["lng"], st["turn"], round(st["along_m"])] for st in route["steps"]],
            "ticks": ticks, "issues": issues}
    out.parent.mkdir(exist_ok=True)
    out.write_text((HERE / "simulate_template.html").read_text().replace("__DATA__", json.dumps(data)))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("log")
    p.add_argument("--route", default="mock/routes/psb_malott.json")
    p.add_argument("--say", default="take me there", help="transcript that starts the trip")
    p.add_argument("--at", type=int, default=15, help="tick to say it (after GPS warm-up)")
    p.add_argument("-o", "--out")
    p.add_argument("--open", action="store_true")
    args = p.parse_args()

    os.environ["ROUTING_MOCK"] = "1"
    os.environ["ROUTING_MOCK_FILE"] = args.route
    ticks, route = simulate(args.log, args.say, args.at)
    if route is None:
        raise SystemExit("No trip started; check --say / --at.")
    issues = find_issues(ticks, route)

    out = Path(args.out or f"viz/sim_{Path(args.log).stem[:8]}.html")
    write_html(ticks, route, issues, out, f"{Path(args.log).stem[:8]} on {Path(args.route).stem}")
    for t in ticks:
        if t["say"]:
            print(f"{t['clock']}  {t['haptic'] or '':10} {t['say']}")
    for issue in issues:
        print(f"! {issue['title']}  -> server said: {issue['server'] or 'nothing'}")
    print(f"wrote {out}")
    if args.open:
        webbrowser.open(out.resolve().as_uri())


if __name__ == "__main__":
    main()
