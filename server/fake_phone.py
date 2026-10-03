"""
Fake iPhone: sends /update requests like the real app and prints what comes back.
Run from server/:
  python fake_phone.py                                   # stand still
  python fake_phone.py --route mock/demo_route.json      # walk the route
  python fake_phone.py --route mock/demo_route.json --transcript "take me to the cafe" --at 2
  python fake_phone.py --replay logs/<session>.jsonl --transcript "take me to Malott" --at 15
  python fake_phone.py --url https://xxx.trycloudflare.com
While it runs, type a line and press Enter to "say" it to the server.
"""
import argparse
import json
import random
import sys
import threading
import time
import uuid
from datetime import datetime, timezone

import httpx

import geo

START = (37.4275, -122.1697)  # where we stand when there's no --route

typed = []  # lines typed into the terminal, waiting to be sent as transcripts


def read_typed_lines():
    """Runs in a background thread: every line you type becomes the next transcript."""
    for line in sys.stdin:
        if line.strip():
            typed.append(line.strip())


def make_update(session_id, lat, lng, heading=0.0, course=0.0, speed=0.0, transcript=None):
    """build a req body"""
    return {
        "session_id": session_id,
        "lat": lat,
        "lng": lng,
        "accuracy_m": 5.0,
        "heading_deg": heading,
        "course_deg": course,
        "speed_mps": speed,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "transcript": transcript,
    }


def load_replay(path):
    with open(path) as f:
        return [json.loads(line)["request"] for line in f if line.strip()]


def walk_position(polyline, meters):
    """Where you are after walking `meters` along the polyline.
    Returns (point, bearing of the current segment, reached_end)."""
    for a, b in zip(polyline, polyline[1:]):
        seg = geo.distance_m(a, b)
        if meters <= seg:
            bearing = geo.bearing_deg(a, b)
            return geo.move(a, bearing, meters), bearing, False
        meters -= seg
    last = tuple(polyline[-1])
    return last, geo.bearing_deg(polyline[-2], last), True


def post(client, url, body):
    """Send one update. Returns the reply dict, or None if anything went wrong."""
    try:
        r = client.post(f"{url}/update", json=body, timeout=5)
        r.raise_for_status()
        return r.json()
    except httpx.HTTPError as e:
        print(f"\n ! {type(e).__name__}: {e}")
        return None


def print_if_changed(reply, prev_state, ms):
    """Print a line when there's something to say or feel, or the state changed; otherwise a dot.
    Returns the state, to compare against next tick."""
    say, haptic, state = reply["say"], reply["haptic"], reply["state"]
    if not say and not haptic and not reply.get("route") and state == prev_state:
        print(".", end="", flush=True)
        return state
    print(f"\n[{state}] {ms:.0f}ms", end="")
    if haptic:
        print(f"  [HAPTIC {haptic}]", end="")
    if say:
        print(f"  say: {say}", end="")
    if reply.get("route"):
        print(f"  route: {len(reply['route'])} turns", end="")
    print(flush=True)
    return state


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://localhost:8000")
    parser.add_argument("--rate", type=float, default=1.0, help="updates per second")
    parser.add_argument("--route", help="route JSON file to walk, e.g. mock/demo_route.json")
    parser.add_argument("--speed", type=float, default=1.4, help="walking speed in m/s")
    parser.add_argument("--replay", help="recorded walk to resend, e.g. logs/<session>.jsonl")
    parser.add_argument("--transcript", help="something to 'say' once, at tick --at")
    parser.add_argument("--at", type=int, default=2, help="tick number for --transcript")
    args = parser.parse_args()

    replay = load_replay(args.replay) if args.replay else None
    polyline = None
    if args.route:
        with open(args.route) as f:
            polyline = json.load(f)["polyline"]

    session_id = str(uuid.uuid4())
    print(f"session {session_id[:8]} -> {args.url}  (type + Enter to speak, Ctrl+C to stop)")
    threading.Thread(target=read_typed_lines, daemon=True).start()

    prev = None
    errors = 0
    walked = 0.0       # meters along the route so far
    at_end = False
    tick = 0
    with httpx.Client() as client:
        try:
            while True:
                if replay:
                    if tick >= len(replay):
                        print(f"\n(end of replay, {len(replay)} ticks)")
                        break
                elif polyline:
                    pos, course, done = walk_position(polyline, walked)
                    speed = 0.0 if done else args.speed
                    heading = (course + random.uniform(-10, 10)) % 360  # phones wobble
                    walked += args.speed / args.rate
                    if done and not at_end:
                        print("\n(end of route, standing still)")
                        at_end = True
                else:
                    pos, course, heading, speed = START, 0.0, 0.0, 0.0

                transcript = None
                if args.transcript and tick == args.at:
                    transcript = args.transcript
                elif typed:
                    transcript = typed.pop(0)
                if transcript:
                    print(f"\n  you said: {transcript!r}")

                if replay:
                    body = dict(replay[tick], session_id=session_id, transcript=transcript)
                else:
                    body = make_update(session_id, pos[0], pos[1], heading=heading,
                                       course=course, speed=speed, transcript=transcript)
                start = time.monotonic()
                reply = post(client, args.url, body)
                ms = (time.monotonic() - start) * 1000

                if reply is None:
                    errors += 1
                    prev = None  # so the first good reply after an error gets printed
                else:
                    prev = print_if_changed(reply, prev, ms)

                tick += 1
                time.sleep(max(0, 1 / args.rate - ms / 1000))
        except KeyboardInterrupt:
            print(f"\nstopped. errors: {errors}")


if __name__ == "__main__":
    main()
