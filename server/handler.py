"""The brain: turns one /update (plus anything the user said) into what the phone should say and do."""
import time

import commands
import geo
import guidance
import routing
import sessions
from models import UpdateResponse

DEDUPE_S = 10
MAX_ACCURACY_M = 30


def handle_update(req, transcript=None):
    s = sessions.get(req.session_id)
    if req.lat is not None and req.lng is not None:
        s["pos"] = (req.lat, req.lng)
    s["accuracy"], s["heading"] = req.accuracy_m, req.heading_deg
    s["course"], s["speed"] = known(req.course_deg), known(req.speed_mps)

    # same timestamp = the phone re-sent its last fix
    fresh = req.timestamp is None or req.timestamp != s["last_fix_ts"]
    s["last_fix_ts"] = req.timestamp
    usable = (fresh and s["pos"] is not None
              and (s["accuracy"] is None or s["accuracy"] <= MAX_ACCURACY_M))

    haptic = None
    if transcript:
        say, haptic = handle_speech(s, transcript)
    elif s["is_new"]:
        say = "Connected. Tap anywhere and say where you'd like to go."
    elif s["state"] in ("navigating", "off_route") and usable:
        say, haptic = guidance.next_instruction(s)
        if say and is_repeat(s, say):
            say, haptic = None, None
    elif s["state"] in ("navigating", "off_route") and fresh and s["pos"] is not None:
        say, haptic = guidance.weak_gps(s)
    else:
        say = None
    s["is_new"] = False
    return build_reply(s, say, haptic)


def reply_to_speech(session_id, transcript):
    """Answer a /listen utterance. Uses the position from the latest /update."""
    s = sessions.get(session_id)
    s["is_new"] = False
    if transcript:
        say, haptic = handle_speech(s, transcript)
    else:
        say, haptic = "Sorry, I didn't catch that.", None
    return build_reply(s, say, haptic)


def build_reply(s, say, haptic):
    if say:
        s["last_say"], s["last_say_t"] = say, time.monotonic()

    route = None
    if s["send_route"]:
        route = [{"lat": st["lat"], "lng": st["lng"], "turn": st["turn"],
                  "instruction": guidance.turn_phrase(st)} for st in s["route"]["steps"]]
        s["send_route"] = False

    return UpdateResponse(say=say, haptic=haptic, state=s["state"], route=route)


def known(value):
    """iOS sends -1 for unknown course/speed."""
    return None if value is None or value < 0 else value


def is_repeat(s, say):
    return say == s["last_say"] and time.monotonic() - s["last_say_t"] < DEDUPE_S


def handle_speech(s, transcript):
    """(say, haptic) in reply to something the user said."""
    action, arg = commands.parse(transcript)

    if action == "empty":
        return "Sorry, I didn't catch that.", None
    if action == "repeat":
        return s["last_say"] or "I haven't said anything yet.", None
    if action == "cancel":
        if s["route"] is None:
            return "There's no route to cancel.", None
        sessions.end_trip(s)
        return "Navigation cancelled.", "tick"
    if action == "status":
        if s["route"] is None or s["pos"] is None:
            return "You're not navigating right now. Tap and say where you'd like to go.", None
        dest = s["route"]["destination"]
        if s["state"] == "arrived":
            return f"You're at {dest['name']}.", None
        return f"{guidance.round_m(guidance.remaining_m(s))} meters to {dest['name']}.", None

    # action == "go"
    if s["pos"] is None:
        return "I don't have your location yet. Give me a moment and try again.", None
    place = routing.find_place(arg, near=s["pos"])
    if place is None:
        return f"Sorry, I couldn't find {arg}.", None
    route = routing.get_route(s["pos"], place)
    sessions.start_trip(s, route)
    return start_sentence(s, route), "tick"


def start_sentence(s, route):
    say = f"Starting route to {route['destination']['name']}, {guidance.round_m(route['distance_m'])} meters."
    poly = route["polyline"]
    if s["heading"] is not None and len(poly) >= 2:
        where = geo.relative_direction(s["heading"], geo.bearing_deg(poly[0], poly[1]))
        say += " Walk straight ahead." if where == "straight ahead" else f" The route starts {where}."
    return say
