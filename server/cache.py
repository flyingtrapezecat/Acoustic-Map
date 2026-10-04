"""Small disk cache for slow or flaky lookups (OpenStreetMap, Gemini), so demo trips work offline."""
import hashlib
import json
from pathlib import Path

DIR = Path(__file__).parent / "cache"


def _path(kind, key):
    return DIR / kind / f"{hashlib.sha1(json.dumps(key, sort_keys=True).encode()).hexdigest()[:16]}.json"


def get(kind, key):
    path = _path(kind, key)
    return json.loads(path.read_text()) if path.exists() else None


def put(kind, key, value):
    path = _path(kind, key)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))
