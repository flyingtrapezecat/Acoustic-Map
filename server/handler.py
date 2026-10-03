"""The brain: turns one /update (plus anything the user said) into what the phone should say and do."""
import time

import commands
import geo
import guidance
import routing
import sessions
from models import UpdateResponse

DEDUPE_S = 10  # don't repeat the same guidance sentence within this many seconds


def handle_update(req, transcript=None):
    s = sessions.get(req.session_id)
    if req.lat is not None and req.lng is not None:
        s["pos"] = (req.lat, req.lng)
    s["accuracy"], s["heading"] = req.accuracy_m, req.heading_deg
    s["course"], s["speed"] = req.course_deg, req.speed_mps

    haptic = None
    if transcript:
        say, haptic = handle_speech(s, transcript)       # the user asked: always answer
    elif s["is_new"]:
        say = "Connected. Tap anywhere and say where you'd like to go."
    elif s["state"] in ("navigating", "off_route"):
        say, haptic = guidance.next_instruction(s)
        if say and is_repeat(s, say):
            say, haptic = None, None
    else:
        say = None
    s["is_new"] = False

    if say:
        s["last_say"], s["last_say_t"] = say, time.monotonic()

    route = None
    if s["send_route"]:
        route = [{"lat": st["lat"], "lng": st["lng"], "turn": st["turn"],
                  "instruction": guidance.turn_phrase(st)} for st in s["route"]["steps"]]
        s["send_route"] = False

    return UpdateResponse(say=say, haptic=haptic, state=s["state"], route=route)


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
        meters = geo.distance_m(s["pos"], (dest["lat"], dest["lng"]))
        return f"{dest['name']} is about {round_m(meters)} meters away.", None

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
    """'Starting route to Demo Cafe, 240 meters. The route starts at your 3 o'clock.'"""
    say = f"Starting route to {route['destination']['name']}, {round_m(route['distance_m'])} meters."
    poly = route["polyline"]
    if s["heading"] is not None and len(poly) >= 2:
        hour = geo.clock_face(s["heading"], geo.bearing_deg(poly[0], poly[1]))
        say += " Walk straight ahead." if hour == 12 else f" The route starts at your {hour} o'clock."
    return say


def round_m(meters):
    """Speak distances in tens: 237 -> 240."""
    return int(round(meters / 10) * 10)
