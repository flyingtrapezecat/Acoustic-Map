"""In-memory session store: one dict per phone, keyed by session_id.
Lost when the server restarts, fine more demo 
"""

_sessions = {}

def _new():
    return {
        "state": "idle",
        "is_new": True,
        "pos": None, "accuracy": None, "course": None, "heading": None, "speed": None,
        "route": None,
        "step_i": 0,
        "announced": set(),
        "progress_m": 0.0, "raw_along_m": 0.0, "off_m": 0.0, "seg_i": 0,
        "last_fix_ts": None, "reassured_at_m": 0.0,
        "send_route": False,
        "last_say": None, "last_say_t": 0.0,
        "bad_off": 0, "bad_wrong": 0, "weak_gps_since": None, "last_reroute_t": 0.0,
        "correction": None, "correction_t": 0.0, "off_since_t": 0.0, "good_ticks": 0,
        "min_raw_m": 0.0, "weak_said": False,
        "correction_repeats": 0, "correction_off_m": 0.0,
        "before_agent": "idle", "agent_places": {},
    }


def get(session_id):
    """The session for this phone, created on first sight"""
    key = session_id or "unknown"
    if key not in _sessions:
        _sessions[key] = _new()
        _sessions[key]["id"] = key
    return _sessions[key]

def start_trip(sesh, route):
    """Put the session on a fresh route."""
    sesh.update(state="navigating", route=route, step_i=0, announced=set(),
             progress_m=0.0, raw_along_m=0.0, off_m=0.0, seg_i=0, reassured_at_m=0.0,
             bad_off=0, bad_wrong=0, send_route=True,
             correction=None, good_ticks=0, weak_gps_since=None, weak_said=False)


def end_trip(sesh):
    """Back to idle, no route."""
    sesh.update(state="idle", route=None, step_i=0, announced=set(), send_route=False)
