"""Server push: say something to a phone at any moment, not only in an /update reply.

notify() sends over the phone's open /events socket. If none is open (or sending fails), the message
waits in an outbox and goes out with the next /update reply instead, so nothing is lost.
Safe to call from any thread (the agent runs in one).
"""
import asyncio
import itertools
import threading

_lock = threading.Lock()
_outbox = {}    # session_id -> [message, ...] waiting for the next /update
_sockets = {}   # session_id -> (event loop, asyncio.Queue feeding that phone's /events socket)
_ids = itertools.count(1)


def notify(session_id, say=None, haptic=None, state=None, route=None, route_line=None):
    msg = {"type": "say", "id": next(_ids), "say": say, "haptic": haptic, "state": state,
           "route": route, "route_line": route_line}
    with _lock:
        live = _sockets.get(session_id)
        if live is None:
            _outbox.setdefault(session_id, []).append(msg)
            return "queued"
    loop, queue = live
    loop.call_soon_threadsafe(queue.put_nowait, msg)
    return "sent"


def connect(session_id):
    """Register an /events socket. Returns its queue, already holding anything that was waiting."""
    queue = asyncio.Queue()
    with _lock:
        for msg in _outbox.pop(session_id, []):
            queue.put_nowait(msg)
        _sockets[session_id] = (asyncio.get_running_loop(), queue)
    return queue


def disconnect(session_id, queue, unsent=()):
    """Unregister the socket; anything it couldn't send goes back to the outbox."""
    with _lock:
        if _sockets.get(session_id, (None, None))[1] is queue:
            del _sockets[session_id]
        left = list(unsent)
        while not queue.empty():
            left.append(queue.get_nowait())
        if left:
            _outbox.setdefault(session_id, [])[:0] = left


def merge(session_id, resp):
    """Put the oldest waiting message into this /update reply, if the reply has nothing to say."""
    if resp.say or resp.state == "listening":
        return resp
    with _lock:
        waiting = _outbox.get(session_id)
        if not waiting:
            return resp
        msg = waiting.pop(0)
    resp.say = msg["say"]
    resp.haptic = msg["haptic"] or resp.haptic
    resp.route = msg["route"] or resp.route
    resp.route_line = msg["route_line"] or resp.route_line
    return resp
