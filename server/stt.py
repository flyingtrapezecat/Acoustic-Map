"""Streams microphone audio to Grok speech-to-text and returns what was said.

Without XAI_API_KEY it runs in mock mode and returns STT_MOCK_TEXT, so the phone side can be built first.
Test against Grok directly:  python stt.py clip.wav
"""
import asyncio
import json
import os
from urllib.parse import urlencode

import websockets

URL = "wss://api.x.ai/v1/stt"
SAMPLE_RATE = 16000
FINALIZE_AFTER_S = 8
GIVE_UP_AFTER_S = 11


async def transcribe(audio, on_partial, keyterms=()):
    """audio: asyncio.Queue of PCM16 mono 16 kHz chunks, None = end. Returns the final text ('' if none)."""
    key = os.getenv("XAI_API_KEY")
    if not key:
        return await _mock(audio, on_partial)

    params = [("sample_rate", SAMPLE_RATE), ("encoding", "pcm"), ("interim_results", "true"),
              ("language", "en"), ("smart_turn", "0.5")] + [("keyterm", k) for k in keyterms]
    async with websockets.connect(f"{URL}?{urlencode(params)}",
                                  additional_headers={"Authorization": f"Bearer {key}"}) as ws:
        first = json.loads(await ws.recv())
        if first.get("type") != "transcript.created":
            raise RuntimeError(f"Grok STT: {first}")

        async def send_audio():
            while (chunk := await audio.get()) is not None:
                await ws.send(chunk)
            await ws.send(json.dumps({"type": "Finalize"}))

        async def finalize_later():
            await asyncio.sleep(FINALIZE_AFTER_S)
            await ws.send(json.dumps({"type": "Finalize"}))

        tasks = [asyncio.create_task(send_audio()), asyncio.create_task(finalize_later())]
        locked = {}  # segment start time -> final text; Grok re-sends a segment when it ends the utterance
        said = lambda extra="": " ".join([locked[k] for k in sorted(locked)] + ([extra] if extra else []))
        try:
            async with asyncio.timeout(GIVE_UP_AFTER_S):
                async for message in ws:
                    event = json.loads(message)
                    kind = event.get("type")
                    if kind == "error":
                        raise RuntimeError(f"Grok STT: {event.get('message')}")
                    if kind == "transcript.done":
                        return event.get("text", "").strip() or said()
                    if kind != "transcript.partial":
                        continue
                    text = event.get("text", "").strip()
                    if event.get("is_final"):
                        if text:
                            locked[event.get("start", len(locked))] = text
                        if event.get("speech_final") and locked:
                            return said()
                        await on_partial(said())
                    elif text:
                        await on_partial(said(text))
        except TimeoutError:
            pass
        finally:
            for t in tasks:
                t.cancel()
        return said()


async def _mock(audio, on_partial):
    seconds = 0.0
    while (chunk := await audio.get()) is not None:
        seconds += len(chunk) / (2 * SAMPLE_RATE)
        if seconds >= 1.5:
            break
    text = os.getenv("STT_MOCK_TEXT", "take me to Malott")
    await on_partial(text.split()[0])
    return text


if __name__ == "__main__":
    import sys
    import wave

    from dotenv import load_dotenv

    load_dotenv()

    async def main(path):
        audio = asyncio.Queue()
        with wave.open(path) as w:
            if (w.getframerate(), w.getnchannels(), w.getsampwidth()) != (SAMPLE_RATE, 1, 2):
                raise SystemExit("need 16 kHz mono 16-bit: ffmpeg -i in.wav -ar 16000 -ac 1 -sample_fmt s16 out.wav")
            frames = w.readframes(w.getnframes())

        async def feed():
            for i in range(0, len(frames), 3200):
                await audio.put(frames[i:i + 3200])
                await asyncio.sleep(0.1)
            await audio.put(None)

        async def show(text):
            print("  partial:", text)

        feeder = asyncio.create_task(feed())
        print("FINAL:", await transcribe(audio, show, ("Malott Hall",)))
        feeder.cancel()

    asyncio.run(main(sys.argv[1]))
