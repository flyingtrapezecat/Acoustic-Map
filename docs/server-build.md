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
| `push.py` | Server push: an outbox per session plus open `/events` sockets; `notify()` | step 7 |
| `stt.py` | Streaming connection to Grok speech-to-text | step 8 |
| `agent.py` | Gemini agent: `reason(session, transcript)`, a tool loop over places, routes and trip status | step 9 |
| `fake_phone.py` | The mock iPhone (walk, replay, listen, events) | steps 1–2, 4–5, 7–8 |
| `grok_probe.py` | A one-off script to test Grok STT on its own | step 8 |
| `mock/demo_route.json`, `mock/routes/*.json` | Hand-made and real routes (`psb_malott.json` is the demo route) | step 2, route-lab |

Dependency order: `main` → `handler` → (`commands`, `agent`, `push`, `routing`, `guidance`, `sessions`) → `geo`. Nothing imports `main`.

The contract for Sophia is in [contract.md](contract.md); the agent's design is in [agent.md](agent.md).

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
  "progress_m": 0.0,          # how far along the route the user has got; only moves forward (see "Route tracking")
  "raw_along_m": 0.0,         # this tick's snapped position along the route; can go backward (wrong-way signal)
  "off_m": 0.0,               # this tick's distance from the route
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
| `relative_direction(facing, bearing)` | "straight ahead", "to your left", "behind you, to your right"… (wide zones, see navigation.md) |
| `cumulative_m(polyline)` | Distance along the route at each vertex: `[0, d01, d01+d12, ...]` |
| `locate(p, polyline, cum, lo, hi)` | `(along_m, off_m, seg_i)`: snaps p onto the route, searching only between `lo` and `hi` meters along it. A flat-earth approximation is fine at walking scale. |

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
  - `prepare(route)` adds `route["cum"] = geo.cumulative_m(polyline)` and an `along_m` to every step.
    It locates each step on the polyline, searching forward from the previous step, so a route that
    passes the same corner twice still gets the right order. Call it on every route, mock or real.
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
  2. Set `state = "navigating"`, `step_i = 0`, `progress_m = 0`, clear `announced`, and `send_route = True`.
  3. Say: "Starting route to Doe Library, 420 meters. The route starts to your right."
- `main.py`: `/update` becomes `resp = handler.handle_update(req, req.transcript)`, then logs and returns it.

**Checkpoint:** `fake_phone.py --route ... --transcript "take me to the library" --at 2` prints the
starting sentence and the state `navigating` once, then dots. `say "cancel"` (typed) brings the state back to `idle`.

## Step 4: Guidance, the happy path (about 45 min)

`guidance.py`. Put the tuning constants at the top: `ARRIVE_M = 12`, `NOW_M = 10`, `AHEAD_M = 40`,
`REASSURE_S = 45`, and for route tracking `BACK_M = 25`, `AHEAD_M_WINDOW = 60`, `MAX_STEP_M = 20`.

**Rules from today's real walks** (handler, before guidance runs):
- **Stale fixes:** if `req.timestamp` equals the last one seen, the phone re-sent an old fix. Skip
  route tracking and the bad-reading counters for that tick.
- **-1 means unknown:** negative `course_deg` or `speed_mps` becomes `None`.
- **Warm-up:** ignore fixes with `accuracy_m > 30` for tracking. The first 10–15 s after launch
  were 36–66 m.
- **Parallel legs:** inside the window, score each candidate as `off_m + 0.2 × max(0, along − progress − 5)`,
  so a slightly closer leg far ahead doesn't win (route-lab's `u_turn` scenario).

Fake phone CP6, `--replay logs/<file>.jsonl`, resends a recorded walk's requests in order under a new
session ID. Step 4 is checked by replaying the real PSB → Malott walks.

`next_instruction(s) -> (say, haptic)` runs checks 2, 4, 6, 7 and 8 from the navigation.md table, in
that order. Each check is a small function returning `(say, haptic)` or `None`, and the first one
that isn't `None` wins. Rules for the individual checks:
- **Route tracking runs first, every tick** (`advance_progress`, see "Route tracking" below).
- **Distance to the next turn** is `steps[step_i]["along_m"] - progress_m`: walking distance along
  the route, not a straight line. That keeps it correct on curved paths.
- **Passed a turn:** `while progress_m >= steps[step_i]["along_m"]: step_i += 1`. If one tick passes
  several turns (for example, a corner was cut), skip all of them silently. Never announce a turn
  that's already behind the user.
- **Turn wording:** "In 40 meters, turn left onto Bancroft Way." Use "Continue straight for 200
  meters" after a turn is passed.

**Checkpoint:** a clean fake walk speaks every turn ahead, every turn now, and then "arrived".
Nothing is said twice and there are no corrections. Watch this with `--speak` on.

### Route tracking: why the search is windowed

Snapping the user to the closest point on the whole route goes wrong in a few common cases:
- **Out-and-back routes, or streets that run side by side.** A noisy fix can be closer to the
  return leg, which would skip turns.
- **GPS jumps.** One bad fix lands 50 m ahead.
- **Corner cutting.** The user is nearer the next segment before reaching the turn point.

So, on each tick:

```python
along, off, seg_i = geo.locate(pos, poly, cum, max(0, progress - BACK_M), progress + AHEAD_M_WINDOW)
if off <= off_limit:                                    # don't let an off-route fix move progress
    progress = min(max(progress, along), progress + MAX_STEP_M)   # never backward, never a leap
```

- **The window** (25 m back, 60 m ahead) only ever considers the stretch of route the user could
  plausibly be on. Already-passed legs and far-ahead legs are invisible to it.
- **`max(progress, along)`** means progress never moves backward, so a passed turn can't come back.
  Walking backward still shows up in `raw_along_m`, which the wrong-way check uses.
- **The `MAX_STEP_M` cap and the off-limit check** stop a single wild fix from skipping turns.
- If the user really does get far ahead of the window (for example, the app was suspended), they
  show as off route, and a reroute starts a fresh route from where they are.

These cases are tested: corner cut, noisy out-and-back, one-tick GPS jump, walking backward, and a curved path.

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
  - Off route → use `off_m` from route tracking, which is measured only within the window.
  - Wrong way → a bad tick is `raw_along_m < progress_m - 8` (the user has moved backward along the
    route) **or** `abs(angle_diff(course, segment bearing)) > 120`. Only check while `speed > 0.5`.
  - After a reroute, `progress_m = 0` on the new route.

**Checkpoint:** `--detour-at 20` → "off route", followed by a new route. `--reverse-at 20` → "turn
around". `--noise 8` → silence apart from the normal instructions.

> **Guidance (steps 4–5) is never cut.** It is the product.

## Step 6: Real routing and places (about 45 min)

The providers are keyless OpenStreetMap services, already proven on campus (the PSB → Malott walks
stayed about 1 m from the route):
- **Routes:** OSRM foot profile, `https://routing.openstreetmap.de/routed-foot/route/v1/driving/{lng},{lat};{lng},{lat}?overview=full&geometries=geojson&steps=true`.
- **Places:** Nominatim, `https://nominatim.openstreetmap.org/search`, with `viewbox` around the user and
  `bounded=1`. Send a `User-Agent` and make at most 1 request per second.

Changes:
- `find_place(text, near)` returns the best match. New: `search_places(query, near, radius_m)` returns
  a ranked list (name, lat, lng, distance, category) for the agent.
- `get_route(start, dest)` converts the OSRM steps into the route shape, as `psb_malott.json` was built.
- Cache both in a dict keyed by the rounded inputs. Keep `ROUTING_MOCK=1` as the demo fallback.
- **Contract:** the reply's `route` comes with a new `route_line` (the full polyline), for the iOS map.

**Built (step 6):** places from `KNOWN_PLACES` then Nominatim; routes to the nearest door (OSM entrances or
hand-picked); OSRM's doorway stub trimmed; path features from Overpass (`paths.py`: stairs, archways,
crossings, which branch at a fork, a building the new path heads toward); steps under 15 m apart said together;
Gemini rewording once per trip (`phrasing.py`, checked, rule wording as fallback); disk cache (`cache.py`,
`python routing.py --warm`); OSRM down → saved route in `mock/routes/` that starts within 80 m.

**Checkpoint:** "Malott Hall" from PSB gives the same route as `mock/routes/psb_malott.json`.

## Step 7: Server push (about 45 min)

The server needs to be able to speak at any moment, for example when the agent finishes, without
waiting for the next `/update`.
- `push.py`:
  - `_outbox[session_id]` is a list of pending messages; `_sockets[session_id]` is the open `/events` WebSocket.
  - `notify(session_id, say=None, haptic=None, state=None, route=None)` sends immediately if a socket is
    open; otherwise it queues the message.
  - `drain(session_id)` hands queued messages to `handle_update`, which merges the first one into the
    `/update` reply.
- `main.py`: `@app.websocket("/events")` registers the socket, keeps it open, and removes it on disconnect.
- Fake phone: `python fake_phone.py events --session <id>` prints every pushed message.

**Checkpoint:**
- With an events terminal open, a test `notify` prints there immediately.
- With it closed, the same message arrives on the next `/update` reply.

## Step 8: Grok voice streaming (about 1.5 h)

1. Run `pip install websockets` (uvicorn needs it for WebSocket endpoints too) and put `XAI_API_KEY` in `.env`.
2. `grok_probe.py`: stream a `say`-generated 16 kHz wav to Grok (read it with `wave`) and print the
   partial and final text. This proves the API key and audio format work, without the server involved.
3. `stt.py`: `async def stream(audio_chunks, on_partial, keyterms) -> str`. Connect, then run two
   tasks at once: one sends the audio chunks, the other reads events. Return the text on the first
   event with `speech_final`. After 10 s, send `Finalize`.
4. `main.py`: add `@app.websocket("/listen")`.
   - Set the session to `listening`, send `ready`, relay audio, forward partials, then set it to `thinking`.
   - Call `handle_speech`. Simple commands reply at once.
   - Agent requests reply with a short acknowledgement, and the answer comes later through `push.notify`.
   - Use `try/finally` so the state always resets.
5. Fake phone: `python fake_phone.py listen clip.wav --session <id>` streams a clip in 100 ms chunks.

**Checkpoint:** while a fake walk is idle in one terminal, `listen clip.wav` in another terminal
starts the trip, and the walk terminal shows `listening` → `thinking` → `navigating`.

> **Cut line:** if streaming isn't working by about 1 AM, demo voice with typed or fake-phone
> transcripts and keep debugging STT in the background.

## Step 9: Gemini agent (about 2 h)

See [agent.md](agent.md). `agent.reason(session, transcript)`:
- Runs in a background thread so `/listen` can return its acknowledgement immediately.
- Calls Gemini with function calling (see agent.md), for at most 4 tool rounds and within 8 s.
- Ends with one spoken reply through `push.notify`.

On a timeout or error it falls back to step 3's plain `find_place` path, so the user always hears something.

**Checkpoint:** every eval prompt in agent.md gives a sensible spoken reply.

> **Cut line:** if this runs late, ship only `search_places` and `start_navigation`.

## Step 10: Hardening and demo insurance (whatever time is left)

- Make sure no error ever leads to silence. Wrap `handle_update` and `reason` in `try/except`: log the
  error and say "Something went wrong, please try again."
- Fill Grok STT's `keyterm` with the destination names in `mock/` and the places found nearby.
- Demo backup: `fake_phone.py --replay` a recorded real walk, plus `ROUTING_MOCK_FILE=mock/routes/psb_malott.json`.
- Commit `requirements.txt` (`pip freeze`) and write down the commands to run the demo.
