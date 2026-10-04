# iOS to-do (Sophia)

What the iPhone app still needs so it can use everything the server now does. The field names and
message shapes are in [contract.md](contract.md); this page is the checklist and how to build each item.
The Swift below is a sketch to show the shape, not code to paste as is.

## Already done
- Background location and speech while locked (`UIBackgroundModes`, `allowsBackgroundLocationUpdates`)
- `heading_deg: null` instead of skipping updates
- Haptic patterns for `turn_left`, `turn_right`, `off_route`, `arrived`, `tick`
- `/listen` voice streaming (but see item 1)

## 1. Microphone sends silence (blocking voice input)
Every recording since about 19:26 is 100% zero samples, so Grok hears nothing and the reply is
"Sorry, I didn't catch that." Microphone permission is fine, and the server and Grok are fine (Grok
transcribed the one recording that had sound).

Most likely cause: `MicrophoneCapture` reuses one `AVAudioEngine` for the whole app while `speak()` and
`start()` keep switching the audio session between `.default` and `.measurement`. After the switch,
the reused engine's tap keeps firing but delivers zeros. The "Connected. Tap anywhere…" greeting
plays just before every mic tap, so it now fails every time.

**Quick check:** cold-launch with Trip Active off (no greeting) and tap the mic immediately. Real audio
then, but zeros right after the greeting, confirms it.

Fix:
- Create a new `AVAudioEngine` for each utterance, and throw it away in `stop()`.
- Use one audio session setup everywhere (the mic, `speak()`, and once at launch), so the mode never changes:
  `setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])`.
  `.measurement` also turns off the mic's automatic gain, which is why the working audio was so quiet.
- Before starting the mic, wait for speech to finish (`stopSpeaking`, then up to about 1 s).
- Raise `.bufferingOldest(20)` to about 100, so a short network stall doesn't end the attempt.
- Optional, but useful: print the peak sample about once a second, and stop with "The microphone is silent"
  after 1.5 s of exact zeros.

Joy has a ready-made patch (`mic_fix.diff`) that does all of this. Ask her for it.

**Test:** with the server running with `RECORD_UPDATES=1`, say "take me to Malott". The server log should show
`audio: N s of audio, level L` with L in the hundreds or more (it's 0 now).

## 2. Receive server pushes: `WS /events` (new, needed for the agent)
The server can now speak at any moment, not only in the `/update` reply. For example, the agent's answer
arrives a few seconds after you finish talking.

What to build:
- **Open the socket at launch** to `wss://<tunnel>/events?session_id=<same sessionID as /update>`, and keep it open.
- **Messages:** each one is a text frame with the same fields as an `/update` reply, plus `type: "say"` and
  an increasing `id`. Send each one through the existing `handleReply`, so speech and haptics work exactly as for `/update`.
  `state` can be null in a push; keep the current state then.
- **Reconnecting:** if the socket closes or errors, reconnect after 1 s, then 2 s, then every 4 s. Nothing
  gets lost while it's down: the server keeps the messages and sends them on the next `/update` reply, or as
  soon as the socket reconnects.
- **Messages go one way.** The phone never sends anything on this socket.

Shape of the client:
```swift
final class EventStream {
    private var task: URLSessionWebSocketTask?
    private var delay = 1.0

    func start(sessionID: String, onReply: @escaping (ServerReply) -> Void) {
        let url = URL(string: ServerConfig.baseURL.replacingOccurrences(of: "https://", with: "wss://")
                      + "/events?session_id=\(sessionID)")!
        let socket = URLSession.shared.webSocketTask(with: url)
        task = socket
        socket.resume()
        Task {
            do {
                while true {
                    if case .string(let text) = try await socket.receive(),
                       let reply = try? JSONDecoder().decode(ServerReply.self, from: Data(text.utf8)) {
                        delay = 1
                        await MainActor.run { onReply(reply) }
                    }
                }
            } catch {
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 4)
                start(sessionID: sessionID, onReply: onReply)   // reconnect
            }
        }
    }
}
// at launch: events.start(sessionID: connection.sessionID) { connection.handleReply($0) }
```

**Test:** `curl -X POST '<tunnel>/debug/say?session_id=<the app's session id>&say=Hello%20from%20the%20server'`.
The phone should speak it within a second. With the app's socket closed, it speaks on the next `/update` instead.

## 3. Draw the route on the map (`route_line`, live now)
- Add `let route_line: [[Double]]?` to `ServerReply`. Each element is `[lat, lng]`.
- **When it arrives:** `route` and `route_line` come once, in the reply that starts a trip or a reroute, and are
  null after that. Keep the last non-null ones and redraw when new ones arrive. A reroute replaces the line.
- **Drawing:**
  - `route_line` as a `MapPolyline`, plus the user's location and the `route` points.
  - `route[].turn` can now also be `slight_left`, `slight_right`, `sharp_left`, `sharp_right`, `uturn`,
    `stairs`, `archway` or `crossing`.
  - Show any you have no icon for as a plain dot. `route[].instruction` is the spoken wording for that point.
- **VoiceOver:** the map is for sighted companions and judges. Hide it from VoiceOver, or give it a one-line summary.

## 4. "Thinking" state (for the agent, step 9)
For open-ended requests ("I'm lost", "what's around me", "somewhere to get coffee"):
- The `/listen` reply is a short acknowledgement, such as "Okay, let me check", with `state: "thinking"`.
- The real answer follows a few seconds later on `/events`, or on the next `/update`.

Nothing new to parse, but:
- Don't treat `thinking` as an error, and don't time out the screen.
- If you show a status, "Thinking…" is enough.
- If the user taps the mic again while thinking, that's fine; the newer request wins.

## 5. Nice to have
- **Siri shortcut** ("Hey Siri, AcousticMaps") that starts listening, for hands-free use while walking.
- **Speech priority:** when a new `say` arrives while one is still being spoken, stop the old one and speak
  the new one. This is already the rule in contract.md; double-check it holds for `/events` messages too.
