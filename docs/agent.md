# Gemini agent: understanding what the user wants

`server/agent.py` turns open-ended speech into actions: picking a place, starting or cancelling a
trip, answering questions about the trip or the surroundings. It runs on **Gemini** with function
calling (`GEMINI_API_KEY`, the same key as the instruction wording in `phrasing.py`). Grok stays for
speech-to-text only. Gemini was chosen over Grok because it qualifies for a sponsor track (the Grok
track requires building in Cursor) and keeps all language work with one provider.

## Where it sits

```
transcript ─► commands.parse ─► cancel / repeat / status ─► answered instantly, no LLM
                     ├─► "take me to <known place>" ─► trip starts instantly, no LLM (demo-safe)
                     └─► anything else ─► agent.reason(session, transcript)   (background thread)
                                             ├─ immediately: "Okay, looking for coffee near you."  state=thinking
                                             └─ ≤ 8 s later: push.notify(final spoken reply, maybe a new route)
```

**The agent never decides turn-by-turn guidance or corrections.** Those stay in `guidance.py`, as
fixed rules that are fast and testable. The agent understands what the user means; the rules keep
them on the path.

## API

- `POST https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent`, header
  `x-goog-api-key: $GEMINI_API_KEY`, through httpx (no SDK).
- Tools are `functionDeclarations` with JSON-Schema `parameters`. The model replies with `functionCall`
  parts; we run them and send back `functionResponse` parts, then loop. The model's turns are sent back
  exactly as received (Gemini 3 needs its `thoughtSignature`s back).
- **Model:** `AGENT_MODEL` in `.env`, default `gemini-3.5-flash-lite` (fast), falling back to
  `gemini-3.1-flash-lite` if it's busy. Thinking is set to minimal.
- **Limits:** at most 4 tool rounds and an 8 s budget overall.

## Tools

These are plain Python functions; each returns a small JSON-able dict.

| Tool | Args | Returns | Calls |
|---|---|---|---|
| `search_places` | `query`, `radius_m=800` | up to 5 × `{place_id, name, category, distance_m, direction}`, nearest first | `KNOWN_PLACES`, then OpenStreetMap (Overpass): a category ("coffee" → cafés) or a name |
| `plan_route` | `place_id` | `{distance_m, turns, minutes}` (doesn't start anything) | `routing.get_route` |
| `start_navigation` | `place_id` | `{started: true, distance_m}`, and the route goes to the phone | `routing.get_route`, `sessions.start_trip` |
| `cancel_navigation` | — | `{cancelled: bool}` | `sessions.end_trip` |
| `trip_status` | — | `{state, destination, remaining_m, minutes, next_instruction, next_turn_m, off_route_m, route_direction}` | session and guidance helpers |
| `describe_surroundings` | — | named buildings and places within ~60 m, each with a left/right/behind direction | Overpass, `geo.relative_direction` |

`place_id`s are short keys into a per-session dict of the last search results, so the model never
has to copy coordinates.

## System prompt (draft)

> You are the voice of AcousticMaps, a walking guide for someone who cannot see the screen.
> Everything you write is spoken aloud. Reply in at most two short sentences. Never refer to
> anything visual ("on the map", "the blue line"). Give distances in meters, rounded to tens, and
> directions as left, right, ahead or behind ("ahead, slightly to your right"), never clock positions.
> Use tools to find places and start navigation; never invent places or distances.
> If a request matches several places and the user didn't say which, ask one short question naming
> the top two. If you can't help, say so plainly and suggest what they can ask.
> Current state: {state}; destination: {destination}; position known: {yes/no}.

## Eval prompts (send each through the fake phone)

| Say | Good outcome |
|---|---|
| "take me to Malott" | Starts navigation to Malott Hall and says the distance |
| "somewhere I can get coffee" | Picks the nearest cafe, says its name and distance, starts navigation |
| "the library" | Asks "Do you mean Uris Library or Olin Library?", or whichever two are nearest |
| "what's around me" | Names 2–3 nearby places with left/right directions |
| "how long until I get there" | Remaining distance and minutes (needs an active trip) |
| "I think I'm lost" | Reassures, gives trip status, and offers to reroute |
| "asdf banana" | "Sorry, I didn't understand. You can say a place, like Malott Hall." |

## Fallbacks

The user must always hear something.
- **Timeout, an API error, or no `GEMINI_API_KEY`:** use step 3's path: `routing.find_place(text)`, then start the trip.
- **The model produces no spoken text:** say "Okay." plus the trip status.
- **Every failure is logged** with the transcript, so the eval list grows from real misses.

## Flow on the phone
1. `/listen` (or a typed transcript) → instant reply "Okay, let me check." with `state: "thinking"` when idle
   (a trip in progress keeps `navigating`, so guidance doesn't stop).
2. Within about 8 s → `push.notify(say, haptic, state, route, route_line)` arrives on `/events`, or on the next `/update`.
