# Grok agent: understanding what the user wants

`server/agent.py` turns open-ended speech into actions: picking a place, starting or cancelling a
trip, answering questions about the trip or the surroundings. It runs on Grok through the xAI
Responses API with function calling. This uses the same `XAI_API_KEY` as speech-to-text.

## Where it sits

```
transcript ─► commands.parse ─► cancel / repeat / status ─► answered instantly, no LLM
                     └─► anything else ─► agent.reason(session, transcript)   (background thread)
                                             ├─ immediately: "Okay, looking for coffee near you."  state=thinking
                                             └─ ≤ 8 s later: push.notify(final spoken reply, maybe a new route)
```

**The agent never decides turn-by-turn guidance or corrections.** Those stay in `guidance.py`, as
fixed rules that are fast and testable. The agent understands what the user means; the rules keep
them on the path.

## API

- `POST https://api.x.ai/v1/responses` with `Authorization: Bearer $XAI_API_KEY`.
- Tools are declared as functions with JSON-Schema `parameters`. The model replies with function
  calls. We run them and send back `{"type": "function_call_output", "call_id": ..., "output": "<json>"}`,
  then loop.
- **Model:** a fast Grok model, since latency matters more than depth here. Check the exact ID with
  `GET https://api.x.ai/v1/models` before hard-coding it, and put it in `.env` as `AGENT_MODEL`.
- **Limits:** at most 4 tool rounds, an 8 s budget overall, and `parallel_tool_calls` left on.

## Tools

These are plain Python functions; each returns a small JSON-able dict.

| Tool | Args | Returns | Calls |
|---|---|---|---|
| `search_places` | `query`, `radius_m=800` | up to 5 × `{place_id, name, category, distance_m, clock}` | `routing.search_places`, `geo.clock_face` |
| `plan_route` | `place_id` | `{distance_m, turns, minutes}` (doesn't start anything) | `routing.get_route` |
| `start_navigation` | `place_id` | `{started: true, distance_m}`, and the route goes to the phone | `routing.get_route`, `sessions.start_trip` |
| `cancel_navigation` | — | `{cancelled: bool}` | `sessions.end_trip` |
| `trip_status` | — | `{state, destination, remaining_m, next_turn, next_turn_m}` | session and guidance helpers |
| `describe_surroundings` | — | named places within ~60 m, each with a clock-face direction | `routing.search_places`, `geo.clock_face` |

`place_id`s are short keys into a per-session dict of the last search results, so the model never
has to copy coordinates.

## System prompt (draft)

> You are the voice of AcousticMaps, a walking guide for someone who cannot see the screen.
> Everything you write is spoken aloud. Reply in at most two short sentences. Never refer to
> anything visual ("on the map", "the blue line"). Give distances in meters, rounded to tens, and
> directions as clock positions ("at your 2 o'clock") or left and right.
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
| "what's around me" | Names 2–3 nearby places with clock directions |
| "how long until I get there" | Remaining distance and minutes (needs an active trip) |
| "I think I'm lost" | Reassures, gives trip status, and offers to reroute |
| "asdf banana" | "Sorry, I didn't understand. You can say a place, like Malott Hall." |

## Fallbacks

The user must always hear something.
- **Timeout, an API error, or no `XAI_API_KEY`:** use step 3's path: `routing.find_place(text)`, then start the trip.
- **The model produces no spoken text:** say "Okay." plus the trip status.
- **Every failure is logged** with the transcript, so the eval list grows from real misses.
