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
| 1 | Weak GPS | Fresh fixes with `accuracy_m > 30` for 10 s | "GPS signal is weak. Keep going carefully." (once per weak spell); those fixes don't move tracking |
| 2 | Arrived | Within 15 m of the destination or the end of the route | "You have arrived at Malott Hall." / `arrived` → state `arrived` |
| 3 | Off route | More than 20 m from the nearby stretch of route, for 3 fresh ticks | "You've left the route. The path is at your 8 o'clock, 20 meters." / `off_route`, state `off_route`; repeated every 15 s with the direction updated. With real routing: reroute if more than 40 m or more than 30 s |
| 4 | Turn now | Within 10 m of the next turn, measured along the route | "Turn left now onto Bancroft Way." / `turn_left` or `turn_right` |
| 5 | Wrong way | Walking (`speed > 0.5`) and moving backward along the route (8 m or more behind progress) for 3 fresh ticks. iOS `course` is **not** used; it lagged and repeated stale values in walk 4 | "You're heading the wrong way. Turn around." / `off_route`; repeated every 15 s |
| 5b | Back on route | While correcting: within 12 m of the route (or walking forward again) for 2 ticks | "You're back on route. The route continues at your 9 o'clock." / `tick` → state `navigating` |
| 6 | Turn ahead | Within 40 m of the next turn, measured along the route, and not yet announced | "In 40 meters, turn left onto Bancroft Way." / `tick` |
| 7 | Passed a turn | Route progress is past the turn. Progress only moves forward, so a passed turn is never announced again. | Move on to the next step. "Continue straight for 200 meters." / `tick` |
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

- `geo.py`: `distance_m`, `bearing_deg`, `move`, `angle_diff`, `clock_face`, plus `cumulative_m` and
  `locate` for route tracking (see server-build.md, "Route tracking"). The fake phone already uses the first three.
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
| `--route mock/demo_route.json` (CP3, walks its `polyline`) | Turn-ahead, turn-now, passed-turn, arrival |
| `--noise 8` (CP7) | Bad GPS doesn't trigger false corrections |
| `--detour-at 20` (CP7) | Off route, then reroute |
| `--reverse-at 20` (CP7, new) | Wrong way → "Turn around" |

The fake phone walks the same `polyline` that routing returns in mock mode, so a clean walk
produces no corrections at all. That is the first thing to verify.

---

## Build order

The current build order lives in [server-build.md](server-build.md) (steps 1–10) for the server, and in
[contract.md](contract.md) for the iOS behavior the server relies on.

Sophia's order:
1. Background location
2. `heading_deg: null` instead of skipping updates
3. `/events` client
4. Map (`route_line`)
5. Mic + `/listen`
6. Siri shortcut
7. Haptic patterns
