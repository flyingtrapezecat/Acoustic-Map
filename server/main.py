from dotenv import load_dotenv
load_dotenv()

import asyncio
import json

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

import handler
import log
import sessions
import stt
from models import UpdateRequest, UpdateResponse

KEYTERMS = ("Malott Hall", "Physical Sciences Building", "PSB")

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

    async def receive_audio():
        try:
            while True:
                msg = await ws.receive()
                if msg["type"] == "websocket.disconnect":
                    break
                if msg.get("bytes"):
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
        await ws.send_json({"type": "reply", **resp.model_dump()})
        await ws.close()
    except WebSocketDisconnect:
        pass
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
