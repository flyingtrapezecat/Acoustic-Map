from dotenv import load_dotenv
load_dotenv()

from fastapi import FastAPI

import log
from models import UpdateRequest, UpdateResponse

log.setup()
app = FastAPI()

@app.get("/health")
def health():
    return {"ok": True}

@app.post("/update")
def update(req: UpdateRequest) -> UpdateResponse:
    resp = UpdateResponse(say="Connected. Hello from the server.", state="idle")
    log.log_update(req, resp)
    return resp

