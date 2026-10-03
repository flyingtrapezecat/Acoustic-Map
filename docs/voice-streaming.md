# Voice streaming: phone → server → Grok

The user taps anywhere on the screen and speaks. Audio streams live to the server, which relays it
to Grok's streaming speech-to-text. Grok decides when the user has stopped talking, and the server
answers with the same four keys as `/update`. There is no "stop" button.

Position updates stay on `POST /update` once a second. That contract is unchanged.

```
 iPhone                         Server (FastAPI)                        Grok STT
 ──────                         ────────────────                        ────────
 tap ─► open WS /listen ───────► accept, state=listening
                                 open wss://api.x.ai/v1/stt ───────────► transcript.created
        ◄── {"type":"ready"} ───
 mic PCM16 chunks (100 ms) ────► forward bytes ────────────────────────►
        ◄── {"type":"partial"} ◄ transcript.partial (interim) ◄────────
                                 ...user stops talking...
                                 ◄── transcript.partial speech_final=true
                                 state=thinking
                                 handle_update(session, transcript)
        ◄── {"type":"reply", say, haptic, state, route}
 speak + vibrate                 close both sockets

 (in parallel, the whole time)
 POST /update once a second ───► returns state=listening / thinking, say=null while the WS is open
```

One WebSocket handles one utterance. Opening it means "start listening"; the server closes it after
the reply. Each tap opens a new socket, so there's no long-lived connection to keep alive.

Voice is how a trip **starts** (or changes destination). The main feature, spoken turn-by-turn
guidance and corrections during the walk, runs on `/update`. See [navigation.md](navigation.md).

## Two ways to start listening

1. **Tap anywhere** on the screen while the app is open.
2. **"Hey Siri, navigate with AcousticMaps"**, for when the user is already walking with the phone
   in a pocket.
   - Sophia adds an App Intent (`StartListeningIntent`, `openAppWhenRun = true`) and an
     `AppShortcutsProvider` with phrases containing `\(.applicationName)`.
   - When it runs, the app speaks "Where to?" and opens `/listen` exactly as a tap would.
   - Siri only launches the app; Grok still does all the transcription. App Shortcut phrases can't
     capture free text like a destination anyway.
   - Test this from the lock screen early. iOS may ask for Face ID before opening the app.

The server can't tell which way listening started, and doesn't need to.

---

## Contract: `WS /listen?session_id=<uuid>`

URL: `wss://<tunnel>.trycloudflare.com/listen?session_id=...` (or `ws://localhost:8000/listen` locally)

**Phone → server**

| Frame | Content |
|---|---|
| binary | Raw PCM16 audio: mono, 16000 Hz, little-endian, no WAV header. About 100 ms per frame (3200 bytes). |
| text | `{"type":"stop"}`: optional. Ends the utterance now (for example, a second tap). |

The phone can start sending audio as soon as the socket opens. The server buffers any audio that
arrives before Grok is ready.

**Server → phone** (all text frames, JSON)

| `type` | Fields | Phone should |
|---|---|---|
| `ready` | — | Optional: a light `tick` haptic so the user knows it's listening |
| `partial` | `text` | Optional: show it on screen. Do not speak it. |
| `reply` | `say`, `haptic`, `state`, `route` | Handle exactly like an `/update` response, then expect the socket to close |

For open-ended requests the agent ([agent.md](agent.md)) runs in the background. The `reply` is then a short
acknowledgement with `state: "thinking"`, and the real answer arrives on `WS /events` (or on the next
`/update`). See [contract.md](contract.md).
| `error` | `message` | Speak "Sorry, I didn't catch that" and close |

If no reply arrives within 15 s, the phone closes the socket and tells the user to try again.

---

## Server side (Joy)

New and changed files:

- `server/sessions.py` (new): an in-memory dict `session_id → {state, destination, ...}`. `/update` reads it,
  so while the WS is open it returns `state: "listening"` and `say: null`. That way the server never
  talks over the user.
- `server/stt.py` (new): the Grok side. Opens `wss://api.x.ai/v1/stt` with `Authorization: Bearer XAI_API_KEY`
  and these query parameters: `sample_rate=16000&encoding=pcm&interim_results=true&language=en&smart_turn=0.5`,
  plus `keyterm` values (destination and place names). Returns the text when an event has `speech_final: true`.
- `server/main.py`: the `@app.websocket("/listen")` endpoint relays the phone's audio to `stt.py` and the
  partials back to the phone. On the final transcript it calls `handle_update()` and sends `reply`.
- Dependency: `pip install websockets`. This is used both to call Grok and by uvicorn itself, which
  can't accept WebSockets without it.
- `.env`: `XAI_API_KEY=...`

Edge cases to handle:
- **Empty transcript:** reply `say: "Sorry, I didn't catch that."`
- **No final transcript after about 10 s:** send `{"type":"Finalize"}` to Grok.
- **Phone disconnects mid-utterance:** close the Grok socket and set the state back to what it was.

## iPhone side (Sophia)

- `Info.plist`: add `NSMicrophoneUsageDescription`.
- `AVAudioSession`: `.playAndRecord`, options `.defaultToSpeaker, .allowBluetooth`.
- On tap: stop any TTS that's playing, so the mic doesn't pick up the app's own voice. Then open a
  `URLSessionWebSocketTask` to `/listen?session_id=...`.
- `AVAudioEngine.inputNode.installTap`: use `AVAudioConverter` to convert to 16 kHz mono Int16, then
  send each roughly 100 ms buffer as `.data`.
- Receive loop: decode the JSON. On `reply`, run the same code path as an `/update` response. Then
  stop the engine and the tap.
- Keep the once-a-second `/update` timer running the whole time.

---

## Voice checkpoints

The overall build order lives in [navigation.md](navigation.md). These are the voice-specific checkpoints within it.

| # | Who | What | Done when |
|---|---|---|---|
| V1 | Joy | `grok_probe.py`: stream a `say`-generated wav directly to Grok, without the server | Partial and final text prints for `say -o clip.wav --data-format=LEI16@16000 "take me to the library"` |
| V2 | Joy | `/listen` relay plus `python fake_phone.py listen clip.wav`, run in a second terminal while the walk runs | The fake phone receives `ready` → `partial`s → `reply`. Meanwhile `/update` shows `listening`/`thinking`. |
| V3 | Sophia | Mic capture plus the `/listen` client, tap to talk | The phone's audio produces partials in the server log |
| V4 | Sophia | Siri App Shortcut opens the app and starts listening | "Hey Siri, navigate with AcousticMaps" → "Where to?" → partials in the server log |
| V5 | Both | Real phone over the cloudflared tunnel (`wss://`) | Tap or Siri, speak, hear the reply, while walking |
| V6 | Joy | Hardening: timeout `Finalize`, empty transcript, disconnects, `keyterm` from nearby places | Bad inputs produce a spoken fallback, never silence |

Notes:
- Read clips with Python's `wave` module, not by skipping 44 bytes. macOS `say` WAV files can have
  extra header chunks.
- Cloudflared quick tunnels pass WebSockets through. Use `wss://` with the same hostname.
- Tune `smart_turn` and `endpointing` outdoors. Street noise can stop a turn from ending, and the
  `Finalize` timeout is the safety net for that.
