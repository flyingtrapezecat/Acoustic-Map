# Server build guide (Joy)

What to build, in order. Each step ends at a checkpoint you can test with the fake phone before
moving on. The behavior is specified in [navigation.md](navigation.md) and
[voice-streaming.md](voice-streaming.md); this file is the how.

## Final file map

Every file stays small and has one job.

| File | Job | Status |
|---|---|---|
| `main.py` | HTTP and WebSocket routes only. No logic. | exists |
| `models.py` | The `/update` contract (request and response) | exists |
| `log.py` | Console log lines and JSONL recording | exists |
| `geo.py` | Distance, bearing, moving a point, distance to a line, angle difference | step 2 |
| `sessions.py` | In-memory store: `session_id → session dict` | step 3 |
| `routing.py` | `find_place()` and `get_route()`; mock mode reads `mock/demo_route.json` | step 3 (mock), step 6 (real) |
| `commands.py` | Turns a transcript into an action: go somewhere, cancel, repeat, where am I | step 3 |
| `handler.py` | `handle_update(req, transcript)`: the brain that `/update` and `/listen` both call | step 3 |
| `guidance.py` | `next_instruction(session)`: the ordered checks table | steps 4–5 |
| `stt.py` | Streaming connection to Grok | step 7 |
| `fake_phone.py` | The mock iPhone | steps 1, 2, 5, 7 |
| `grok_probe.py` | A one-off script to test Grok on its own | step 7 |
| `mock/demo_route.json` | One hand-made route near the venue | step 2 |

Dependency order: `main` → `handler` → (`commands`, `routing`, `guidance`, `sessions`) → `geo`. Nothing imports `main`.

---

## Shared data shapes (agree on these once)

**Route** (returned by `routing.get_route`, stored on the session, and also the format of `mock/demo_route.json`):

```python
{
  "destination": {"name": "Doe Library", "lat": 37.8723, "lng": -122.2595},
  "polyline": [[lat, lng], [lat, lng], ...],     # the full walking line, used for off-route checks
  "distance_m": 420,
  "steps": [                                     # one per turn, the last one is the arrival point
    {"lat": ..., "lng": ..., "turn": "left",  "street": "Bancroft Way", "distance_m": 120},
    {"lat": ..., "lng": ..., "turn": "right", "street": "College Ave",  "distance_m": 200},
    {"lat": ..., "lng": ..., "turn": "arrive", "street": "",           "distance_m": 100},
  ],
}
```
`distance_m` on a step is the walk from the previous step to this one.

**Session** (created by `sessions.get(session_id)`):

```python
{
  "state": "idle",            # idle | listening | thinking | navigating | off_route | arrived
  "pos": None, "accuracy": None, "course": None, "heading": None, "speed": None,
  "route": None,              # the route dict above
  "step_i": 0,                # index of the next turn in route["steps"]
  "announced": set(),         # e.g. {"0:ahead", "0:now"}, so nothing is said twice
  "closest_to_step": inf,     # smallest distance to the current step seen so far (to detect a passed turn)
  "send_route": False,        # True → include route in the next response, then reset
  "last_say": None, "last_say_t": 0.0,
  "bad_off": 0, "bad_wrong": 0, "weak_gps_since": None, "last_reroute_t": 0.0,
}
```

---

## Step 1: Fake phone CP1–CP2 (about 20 min)

`fake_phone.py`:
- `make_update(session_id, lat, lng, **extra) -> dict` builds one request body.
- `post(client, url, body) -> dict | None` sends it. On any `httpx` error, print it and return `None`
  instead of crashing.
- `print_if_changed(reply, prev)` prints `say`, `haptic` and `state` when they change, otherwise a dot.
- The main loop sleeps `1 / rate` between requests. Ctrl+C exits cleanly.

**Checkpoint:** the loop prints dots, and stopping and starting uvicorn shows errors followed by a recovery.

## Step 2: `geo.py` + mock route + walking (about 40 min)

`geo.py`, plain math, no libraries. Points are `(lat, lng)` tuples.

| Function | Returns |
|---|---|
| `distance_m(a, b)` | Haversine distance in meters |
| `bearing_deg(a, b)` | Compass bearing 0–360 from a to b |
| `move(a, bearing, meters)` | The point you reach walking that far in that direction |
| `angle_diff(a, b)` | The signed difference -180…180 (positive means b is clockwise of a) |
| `clock_face(heading, bearing)` | 1–12, e.g. `3` means "at your 3 o'clock" |
| `distance_to_line(p, polyline)` | `(meters, segment_index)`: the smallest distance from p to the route, and which segment is closest (the wrong-way check needs its bearing). A flat-earth approximation is fine at walking scale. |

`mock/demo_route.json`: build it by hand. In Google Maps, right-click a street corner to copy its
coordinates. Choose 3–4 corners near the venue and make one turn left and one turn right.

`fake_phone.py --route mock/demo_route.json --speed 1.4` walks that route's `polyline`. Each tick,
advance `speed / rate` meters along the line and set:
- `course_deg` to the segment bearing
- `heading_deg` to the course plus ±10° of jitter
- `speed_mps` to the walking speed
- `accuracy_m` to 5

When it reaches the end, it stands still.

**Checkpoint:** `distance_m` between two corners roughly matches Google Maps' "Measure distance".
The uvicorn log shows positions moving along the route.

## Step 3: Sessions, handler, commands, mock routing (about 45 min)

- `sessions.py`: `get(session_id) -> dict` creates the session with the defaults above if it's new.
- `routing.py`: `MOCK = os.getenv("ROUTING_MOCK") == "1"`.
  - `find_place(text, near)` returns the mock destination when `MOCK` is set.
  - `get_route(start, end)` returns the mock route, starting from the first polyline point.
- `commands.py`: `parse(transcript) -> (action, arg)`, using lowercase keyword matching:
  - "cancel" / "stop" → `("cancel", None)`
  - "repeat" / "say again" → `("repeat", None)`
  - "where am i" / "how far" → `("status", None)`
  - anything else → `("go", text)`. Strip "take me to", "navigate to", "go to" from the start.
- `handler.py`, `handle_update(req, transcript=None) -> UpdateResponse`:
  1. `s = sessions.get(req.session_id)`, then copy the position fields onto it.
  2. If there's a transcript, `say, haptic = handle_speech(s, transcript)`.
  3. Else, if the state is `navigating` or `off_route`, `say, haptic = guidance.next_instruction(s)`. (Until step 4, this returns `None, None`.)
  4. Pass `say` through `dedupe(s, say)`: drop it if it's the same text as `last_say` within 10 s.
  5. Include `route=s["route"]["steps"]` only if `send_route` is set, then reset the flag.
- `handle_speech` for `go`:
  1. Find the place and get the route.
  2. Set `state = "navigating"`, `step_i = 0` and `send_route = True`.
  3. Say: "Starting route to Doe Library, 420 meters. The route starts at your 4 o'clock."
- `main.py`: `/update` becomes `resp = handler.handle_update(req, req.transcript)`, then logs and returns it.

**Checkpoint:** `fake_phone.py --route ... --transcript "take me to the library" --at 2` prints the
starting sentence and the state `navigating` once, then dots. `say "cancel"` (typed) brings the state back to `idle`.

## Step 4: Guidance, the happy path (about 45 min)

`guidance.py`. Put the tuning constants at the top: `ARRIVE_M = 12`, `NOW_M = 10`, `AHEAD_M = 40`,
`PASSED_M = 15`, `REASSURE_S = 45`.

`next_instruction(s) -> (say, haptic)` runs checks 2, 4, 6, 7 and 8 from the navigation.md table, in
that order. Each check is a small function returning `(say, haptic)` or `None`, and the first one
that isn't `None` wins. Rules for the individual checks:
- **Passed a turn:** track `closest_to_step`. Once it has been under `PASSED_M` and the current
  distance is 5 m or more above it, increment `step_i` and reset `closest_to_step`.
- **Turn wording:** "In 40 meters, turn left onto Bancroft Way." Use "Continue straight for 200
  meters" after a turn is passed.

**Checkpoint:** a clean fake walk speaks every turn ahead, every turn now, and then "arrived".
Nothing is said twice and there are no corrections. Watch this with `--speak` on.

## Step 5: Corrections + fake phone CP7 (about 45 min)

- **Fake phone flags:**
  - `--noise M` adds random GPS error of up to M meters.
  - `--detour-at N` turns 90° off the route at tick N.
  - `--reverse-at N` turns 180° at tick N.
- **Checks 1, 3 and 5 in `guidance.py`:**
  - Use the counters `bad_off` and `bad_wrong`. Increment on a bad tick, reset to 0 on a good one,
    and fire at 3.
  - Off route → `state = "off_route"`. Then reroute: call `get_route(pos, destination)`, set
    `send_route`, and go back to `navigating`. Reroute at most once every 15 s.
  - Wrong way → compare `course` with the bearing of the closest polyline segment using `angle_diff`.
    Only check while `speed > 0.5`.

**Checkpoint:** `--detour-at 20` → "off route", followed by a new route. `--reverse-at 20` → "turn
around". `--noise 8` → silence apart from the normal instructions.

> **Cut line:** if you're behind schedule at this point, skip step 6. Demo on the mock route and go
> straight to step 7. Voice is the sponsor track.

## Step 6: Real routing (about 45 min)

Once the provider is chosen, swap the bodies of `find_place` and `get_route` to use `httpx`. They
return exactly the route shape above, so nothing else changes. Pass `near=pos` to the place search
so "the library" resolves to the one nearby. Keep `ROUTING_MOCK=1` available as a demo fallback.

**Checkpoint:** typing a real place near the venue gives a route whose turns match Google Maps.

## Step 7: Grok streaming (about 1.5 h)

1. Run `pip install websockets` and put `XAI_API_KEY` in `.env`.
2. `grok_probe.py`: stream a `say`-generated 16 kHz wav to Grok (read it with `wave`) and print the
   partial and final text. This proves the API key and audio format work, without the server involved.
3. `stt.py`: `async def stream(audio_chunks, on_partial, keyterms) -> str`. Connect, then run two
   tasks at once: one sends the audio chunks, the other reads events. Return the text on the first
   event with `speech_final`. After 10 s, send `Finalize`.
4. `main.py`: add `@app.websocket("/listen")`.
   - Set the session to `listening`, send `ready`, relay audio, forward partials, then set it to `thinking`.
   - Call `handle_update(..., transcript=text)` and send `reply`, then close.
   - Use `try/finally` so the state always resets.
5. Fake phone: `python fake_phone.py listen clip.wav --session <id>` streams a clip in 100 ms chunks.

**Checkpoint:** while a fake walk is idle in one terminal, `listen clip.wav` in another terminal
starts the trip, and the walk terminal shows `listening` → `thinking` → `navigating`.

## Step 8: Hardening + demo insurance (whatever time is left)

- Make sure no error ever leads to silence. Wrap `handle_update` in a `try/except`: log the error
  and reply "Something went wrong, please try again."
- Fill Grok's `keyterm` with the destination names in `mock/` and the places found nearby.
- Do a real walk with Sophia with `RECORD_UPDATES=1`. Then `fake_phone.py --replay` that file, so
  the demo has a backup that doesn't need GPS.
- Commit `requirements.txt` (`pip freeze`) and write down the commands to run the demo.
