# Navigation guidance: the main feature

Once there's a destination, the phone mostly listens. Every `/update` (once a second), the server
decides whether to say something, which haptic to fire, and whether the user has gone wrong. Voice
input ([voice-streaming.md](voice-streaming.md)) is only how a trip starts. This is the part users
spend 99% of the trip in.

## Trip lifecycle

```
idle ──(Siri / tap, "take me to X")──► listening ──► thinking ──► navigating ◄──────┐
                                         (Grok)     (find place,      │             │
                                                     get route)       ├─► off_route ─┘ (reroute)
                                                                      └─► arrived ──► idle
```

## What happens on each `/update` tick (state = navigating)

Run these checks in order. **The first one that fires is what gets said this tick**: at most one
`say` per tick, so instructions never pile up.

| # | Check | Condition (starting values; tune outdoors) | say / haptic |
|---|---|---|---|
| 0 | Mute | Session is `listening` or `thinking` | `null`. Never talk over the user. |
| 1 | Bad GPS | `accuracy_m > 30` | Don't correct anything this tick. If it lasts 10 s, say "GPS signal is weak" once. |
| 2 | Arrived | Within 12 m of the destination | "You've arrived at Doe Library." / `arrived` → state `arrived` |
| 3 | Off route | More than `max(20 m, 1.5 × accuracy)` from the route line, for 3 ticks in a row | "You've gone off the route. Finding a new one." / `off_route`, then reroute (at most once per 15 s) and send the new `route` |
| 4 | Turn now | Within 10 m of the next turn point | "Turn left now onto Bancroft Way." / `turn_left` or `turn_right` |
| 5 | Wrong way | Walking (`speed_mps > 0.5`) and `course_deg` more than 120° off the route's direction, for 3 ticks | "You're heading the wrong way. Turn around." / `off_route` |
| 6 | Turn ahead | Within 40 m of the next turn, and not yet announced | "In 40 meters, turn left onto Bancroft Way." / `tick` |
| 7 | Passed a turn | Distance to the turn point grows after it was under 15 m | Move on to the next step. "Continue straight for 200 meters." / `tick` |
| 8 | Reassurance | Nothing said for 45 s | "Still on route. 120 meters to the next turn." |

Rules that apply to every message:
- **Don't repeat yourself.** The same sentence can't be said again within 10 s. Each step remembers which
  announcements it has made (`ahead`, `now`).
- **Corrections need consistency.** Checks 3 and 5 need 3 bad ticks in a row, because one jumpy GPS
  fix should never make the app tell a person to turn around.
- **Clock-face directions for the first orientation.** At trip start, compare `heading_deg` (where the
  phone points) with the first segment's bearing: "The route starts at your 4 o'clock. Turn right,
  then walk straight." This is a standard convention for blind navigation and fixes the most common
  confusion at the start.

## Server files (Joy)

- `geo.py`: `distance_m`, `bearing_deg`, `move`, plus `distance_to_line(point, polyline)` and
  `angle_diff(a, b)`. The fake phone already uses the first three.
- `routing.py`:
  - `find_place(text, near) -> (name, lat, lng)` turns a spoken destination into coordinates.
  - `get_route(start, end) -> {polyline, steps}` returns the walking route.
    - Each step: `{lat, lng, turn: "left" | "right" | "straight", street, distance_m}`.
  - With `ROUTING_MOCK=1` in `.env`, both return `mock/demo_route.json`. That way you can develop and
    demo without the network or a routing API.
- `guidance.py`: one function, `next_instruction(session, update) -> (say, haptic, state)`. It is the
  table above, as plain `if` statements in order. All the tuning numbers live at the top of the file.
- `sessions.py`: the trip state per session (route, step index, announced flags, last message, bad-tick counters).

**`route` field in the contract:** a list of the turn points
`[{lat, lng, instruction, turn}]`, sent only on the tick the route is created or changed. The phone
can draw it, but it never has to understand it.

## iPhone side (Sophia)

- **Keep running while the phone is locked in a pocket.** This is required for the main feature.
  - Add `UIBackgroundModes`: `location` and `audio`.
  - Set `allowsBackgroundLocationUpdates = true`.
  - Request "Always" location permission, or at least "When In Use" while a trip is active.
  - Send `/update` from the `CLLocationManager` delegate, not from a `Timer`, because timers stop
    running in the background. Set `distanceFilter = kCLDistanceFilterNone` so updates still arrive
    about once a second.
- **Speaking:** `AVSpeechSynthesizer` with an audio session that ducks other audio (music gets quieter
  while it speaks). If a new `say` arrives while it's still talking, stop and speak the new one, since
  the newest instruction matters most.
- **Haptics:** give each haptic a pattern people can tell apart without looking:
  - `turn_left`: 2 short pulses
  - `turn_right`: 3 short pulses
  - `off_route`: 1 long pulse
  - `arrived`: a success pattern
  - `tick`: 1 light pulse

## Testing with the fake phone (no walking needed)

| Fake phone flag | Tests |
|---|---|
| `--route mock/demo_walk.json` (CP3) | Turn-ahead, turn-now, passed-turn, arrival |
| `--noise 8` (CP7) | Bad GPS doesn't trigger false corrections |
| `--detour-at 20` (CP7) | Off route, then reroute |
| `--reverse-at 20` (CP7, new) | Wrong way → "Turn around" |

`mock/demo_walk.json` should follow the same streets as `mock/demo_route.json`, so a clean walk
produces no corrections at all. That is the first thing to verify.

---

## Overall build order (both docs)

Main feature first; voice second.

| # | Who | What | Done when |
|---|---|---|---|
| 1 | Joy | Fake phone CP1–CP2 (one request, then the once-a-second loop) | The loop runs and survives a server restart |
| 2 | Joy | Fake phone CP3: mock walking data + `geo.py` | Positions move along the path in Google Maps |
| 3 | Joy | `sessions.py` + `routing.py` in mock mode. A typed transcript (`--transcript "library"`) starts a trip. | `/update` returns `navigating` and the `route` once |
| 4 | Joy | `guidance.py` checks 2, 4, 6, 7 (arrival and turns) | A clean mock walk speaks every turn and then "arrived", with no corrections |
| 5 | Joy | Fake phone CP7 + `guidance.py` checks 1, 3, 5, 8 (corrections) | Detour → reroute, reverse → "Turn around", noise → silence |
| 6 | Joy | Real `routing.py` (live place lookup and routes) | Typed destinations near the venue give real routes |
| 7 | Joy | Grok: `grok_probe.py`, then the `/listen` relay ([voice-streaming.md](voice-streaming.md)) | The fake phone streams a clip and a trip starts |
| S1 | Sophia | Background location + `/update` from the location delegate, speech, haptic patterns | A locked phone in a pocket keeps speaking the server's `say` |
| S2 | Sophia | Mic + `/listen` client, tap to talk | Partials appear in the server log |
| S3 | Sophia | Siri App Shortcut (see voice-streaming.md) | "Hey Siri, navigate with AcousticMaps" starts listening |
| 8 | Both | Real walk over the tunnel with `RECORD_UPDATES=1` | A full trip works; keep the recording for replay as a demo backup |
