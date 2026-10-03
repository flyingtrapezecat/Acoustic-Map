"""
Fake iPhone: sends /update requests like the real app and prints what comes back
"""
import argparse
import time
import uuid
from datetime import datetime, timezone

import httpx

def make_update(session_id, lat, lng, transcript=None):
    """build a req body"""
    return {
        "session_id": session_id,
        "lat": lat,
        "lng": lng,
        "accuracy_m": 5.0,
        "heading_deg": 0.0,
        "course_deg": 0.0,
        "speed_mps": 0.0,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "transcript": transcript,
    }

def post(client, url, body):
    """Send one update. Returns the reply dict, or None if anything went wrong."""
    try:
        r = client.post(f"{url}/update", json=body, timeout=5)
        r.raise_for_status()
        return r.json()
    except httpx.HTTPError as e:
        print(f"\n ! {type(e).__name__}: {e}")
        return None

def print_if_changed(reply, prev, ms):
    """print say/haptic/state when they change, otherwise ."""
    key = (reply["say"], reply["haptic"], reply["state"])
    if key == prev:
        print(".", end="", flush=True)
        return prev
    say, haptic, state = key
    print(f"\n[{state}] {ms:.0f}ms", end="")
    if haptic:
        print(f"  [HAPTIC {haptic}]", end="")
    if say:
        print(f"  say: {say}", end="")
    if reply.get("route"):
        print(f"  route: {len(reply['route'])} turns", end="")
    print(flush=True)
    return key

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://localhost:8000")
    parser.add_argument("--rate", type=float, default=1.0, help="updates per second")
    args = parser.parse_args()

    session_id = str(uuid.uuid4())
    print(f"session {session_id[:8]} -> {args.url}  (Ctrl+C to stop)")

    prev = None
    errors = 0
    with httpx.Client() as client:
        try:
            while True:
                body = make_update(session_id, 37.4275, -122.1697)
                start = time.monotonic()
                reply = post(client, args.url, body)
                ms = (time.monotonic() - start) * 1000

                if reply is None:
                    errors += 1
                    prev = None  # so the first good reply after an error gets printed
                else:
                    prev = print_if_changed(reply, prev, ms)

                time.sleep(max(0, 1 / args.rate - ms / 1000))
        except KeyboardInterrupt:
            print(f"\nstopped. errors: {errors}")

if __name__ == "__main__":
    main()