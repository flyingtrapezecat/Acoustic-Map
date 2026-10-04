from dotenv import load_dotenv
load_dotenv()

import asyncio
import json
# audio debug: saves each utterance to logs/audio/ (with RECORD_UPDATES=1) and logs its level
import array, math, os, time, wave
from pathlib import Path

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

import handler
import log
import sessions
import stt
from models import UpdateRequest, UpdateResponse

KEYTERMS = ("Malott Hall", "Physical Sciences Building", "PSB")
AUDIO_DIR = Path(__file__).parent / "logs" / "audio"  # audio debug

log.setup()
app = FastAPI()

@app.get("/health")
def health():
    return {"ok": True}

@app.post("/update")
def update(req: UpdateRequest) -> UpdateResponse:
    resp = handler.handle_update(req, req.transcript)
    log.log_update(req, resp)
    return resp

@app.websocket("/listen")
async def listen(ws: WebSocket, session_id: str = ""):
    """One utterance: phone streams PCM16 audio, we send ready/partial/reply, then close."""
    await ws.accept()
    s = sessions.get(session_id)
    before = s["state"]
    s["state"] = "listening"
    audio = asyncio.Queue()
    heard = bytearray()  # audio debug

    async def receive_audio():
        try:
            while True:
                msg = await ws.receive()
                if msg["type"] == "websocket.disconnect":
                    break
                if msg.get("bytes"):
                    heard.extend(msg["bytes"])  # audio debug
                    await audio.put(msg["bytes"])
                elif msg.get("text") and json.loads(msg["text"]).get("type") == "stop":
                    break
        finally:
            await audio.put(None)

    async def send_partial(text):
        await ws.send_json({"type": "partial", "text": text})

    receiver = asyncio.create_task(receive_audio())
    try:
        await ws.send_json({"type": "ready"})
        text = await stt.transcribe(audio, send_partial, KEYTERMS)
        s["state"] = before if before not in ("listening", "thinking") else "idle"
        resp = await asyncio.to_thread(handler.reply_to_speech, session_id, text)
        log.logger.info("%s heard %r -> %r", session_id[:8], text, resp.say)
        log.logger.info("%s audio: %s", session_id[:8], save_audio(session_id, heard))  # audio debug
        await ws.send_json({"type": "reply", **resp.model_dump()})
        await ws.close()
    except WebSocketDisconnect:
        log.logger.info("%s phone hung up before the reply", session_id[:8])
    except Exception as e:
        log.logger.exception("listen failed")
        try:
            await ws.send_json({"type": "error", "message": str(e)})
            await ws.close()
        except Exception:
            pass
    finally:
        receiver.cancel()
        if s["state"] in ("listening", "thinking"):
            s["state"] = before if before not in ("listening", "thinking") else "idle"


# audio debug
def save_audio(session_id, pcm):
    """Describe (and with RECORD_UPDATES=1, save) what the phone sent, to debug recognition."""
    samples = array.array("h", bytes(pcm[: len(pcm) // 2 * 2]))
    level = math.sqrt(sum(x * x for x in samples) / len(samples)) if samples else 0
    info = f"{len(samples) / 16000:.1f} s of audio, level {level:.0f}"
    if os.getenv("RECORD_UPDATES") == "1" and samples:
        AUDIO_DIR.mkdir(parents=True, exist_ok=True)
        path = AUDIO_DIR / f"{session_id[:8]}-{time.strftime('%H%M%S')}.wav"
        with wave.open(str(path), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes(samples.tobytes())
        info += f", saved {path.relative_to(Path(__file__).parent)}"
    return info
