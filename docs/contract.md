# Phone ↔ server contract

This is the one page the iOS app builds against. Field names don't change without telling Sophia.
Base URL: `https://<tunnel>.trycloudflare.com` (it changes if cloudflared restarts).

| Channel | Direction | When | Status |
|---|---|---|---|
| `POST /update` | phone → server, reply back | once a second, always | **live** |
| `WS /events?session_id=` | server → phone | keep open for the whole session | server step 7 |
| `WS /listen?session_id=` | phone → server (audio), replies back | one socket per utterance (tap or Siri) | **live** (mock speech until the xAI key is set: any audio → "take me to Malott") |

## The reply shape (the same on all three channels)

```json
{
  "say": "In 40 meters, turn left.",      // string or null. Speak it now and interrupt anything older.
  "haptic": "turn_left",                  // null | tick | turn_left | turn_right | off_route | arrived
  "state": "navigating",                  // idle | listening | thinking | navigating | off_route | arrived
  "route": [ {"lat": 42.4496, "lng": -76.4822, "turn": "left", "instruction": "turn left"} ],
  "route_line": [[42.4496, -76.4818], [42.4496, -76.4822]]
}
```

- **`route` and `route_line` are sent once,** when a trip starts or is rerouted. Otherwise they're
  null. Keep the last ones you received for the map.
- `route` holds the turn points, and the last one has `turn: "arrive"`. `route_line` is the full
  walking path, for drawing a `MapPolyline`. **`route_line` is live** (server step 6).
- `turn` values: `left`, `right`, `slight_left`, `slight_right`, `sharp_left`, `sharp_right`, `uturn`,
  `arrive`, and the path features `stairs`, `archway`, `crossing` (new in step 6; draw them as plain
  points if you have no icon). `instruction` is the spoken wording for that point.
- **`say` is never repeated by the server,** so speak every non-null one you get.

## `POST /update` (live)

Request body: all fields are optional, and the server accepts missing ones.

| Field | Type | Notes |
|---|---|---|
| `session_id` | string | `UUID().uuidString`, once per app launch |
| `lat`, `lng` | number | |
| `accuracy_m` | number | `horizontalAccuracy` |
| `heading_deg` | number or null | **Send null when there's no heading yet. Don't skip the update.** |
| `course_deg`, `speed_mps` | number | -1 when unknown is fine; the server treats negatives as missing |
| `timestamp` | string | **`location.timestamp`, not `Date()`.** The server uses it to spot re-sent fixes. |
| `transcript` | string or null | null; voice goes through `/listen` |

Response: the reply shape above. One reply can also carry a message the server queued for you
because `/events` wasn't connected.

## `WS /events?session_id=` (server step 7)

- Open it at launch and keep it open. If it drops, reconnect after 1 s, 2 s, then 4 s, and keep
  retrying every 4 s.
- The server sends text frames shaped like the reply above, plus `"type": "say"` and an increasing `"id"`.
- Handle each one exactly like an `/update` reply.
- It's used for anything the server wants to say outside the once-a-second rhythm. Most often that's
  the agent's answer after "thinking".
- If the socket is down, nothing is lost: the message arrives on the next `/update` reply instead.

## `WS /listen?session_id=` (live)

- **Test it before the mic works:** connect, send about 1.5 s of any PCM16 audio (even silence), and you get
  `ready`, a `partial`, then a `reply` that starts the PSB → Malott trip.
- **Use the same `session_id` as `/update`,** so the server knows where you are. Without a recent
  `/update`, the reply is "I don't have your location yet."
- **While the socket is open, `/update` replies with `state: "listening"` and `say: null`.**

The full details are in [voice-streaming.md](voice-streaming.md). In short:

| Phone → server | Server → phone |
|---|---|
| Binary frames: PCM16 audio, mono, 16 kHz, about 100 ms (3200 bytes) per frame | `{"type":"ready"}`, `{"type":"partial","text"}` |
| `{"type":"stop"}` (optional) | `{"type":"reply", ...reply shape}`, then the server closes the socket |

**New since the voice doc:** for open-ended requests ("somewhere to get coffee"), the `reply` may be a
short acknowledgement with `state: "thinking"`, such as "Okay, looking for coffee near you." The real
answer arrives a few seconds later on `/events`, or on the next `/update`.

## iOS behavior the server relies on

1. **Background location** (`UIBackgroundModes: location, audio`, `allowsBackgroundLocationUpdates`).
   Without it, a locked phone sends nothing; a test lock gave a 43 s gap.
2. **Send `/update` from the location callback,** because timers stop in the background.
3. **When a new `say` arrives, stop the current speech and speak the new one.**
4. **Make the haptics distinguishable without looking:**
   - `turn_left`: 2 short pulses
   - `turn_right`: 3 short pulses
   - `off_route`: 1 long pulse
   - `arrived`: success pattern
   - `tick`: 1 light pulse
5. **The map is a visual extra** for judges and sighted companions:
   - draw `route_line`, the user's location, and the turn points;
   - hide it from VoiceOver, or give it a one-line summary.
