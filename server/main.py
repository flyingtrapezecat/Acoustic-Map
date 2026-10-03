from dotenv import load_dotenv
load_dotenv()

from fastapi import FastAPI

import handler
import log
from models import UpdateRequest, UpdateResponse

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

