import json
import logging
import os
from datetime import datetime
from pathlib import Path

LOG_DIR = Path(__file__).parent / "logs"
RECORD = os.getenv("RECORD_UPDATES", "0") == "1"

logger = logging.getLogger("acoustic")

def setup():
    level = os.getenv('LOG_LEVEL', "INFO").upper()
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(message)s",
        datefmt="%H:%M:%S"
    )
    if RECORD:
        LOG_DIR.mkdir(exist_ok=True)
        logger.info("Recording updates to %s", LOG_DIR)

def log_update(req, resp):
    """Call once per /update with parsed request and response we're about to send"""
    logger.info("%s @ %s,%s ±%sm  say=%r state=%s",
                (req.session_id or "?")[:8], req.lat, req.lng, req.accuracy_m,
                resp.say, resp.state)
    if req.transcript:
        logger.info("  heard: %r", req.transcript)
    logger.debug("  full request: %s", req.model_dump())

    if RECORD:
        line = {"t": datetime.now().isoformat(),
                "request": req.model_dump(),
                "response": resp.model_dump()}
        path = LOG_DIR / f"{req.session_id or 'unknown'}.jsonl"
        with path.open("a") as f:
            f.write(json.dumps(line) + "\n")