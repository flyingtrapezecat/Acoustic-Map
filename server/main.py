from datetime import datetime

from fastapi import FastAPI

from models import UpdateRequest, UpdateResponse

app = FastAPI()

@app.get("/health")
def health():
    return {"ok": True}

@app.post("/update")
def update(req: UpdateRequest) -> UpdateResponse:
    now = datetime.now().strftime("%H:%M:%S")
    print(f"[{now}] {req.session_id} @ {req.lat},{req.lng} "
          f"±{req.accuracy_m}m  transcript={req.transcript!r}")
    return UpdateResponse(say="Connected. Hello from the server.", state="idle")