"""Gemini agent for open-ended requests ("somewhere to get coffee", "I'm lost", "what's around me").

handler.handle_speech replies "Okay, let me check." right away and runs reason() in a background thread.
Gemini calls the tools below (at most MAX_ROUNDS rounds, within BUDGET_S); the answer goes to the phone
with push.notify. The agent never does turn-by-turn guidance or corrections: guidance.py keeps those.

Try it:  python agent.py "somewhere I can get coffee"   (from PSB; --at lat,lng to move)
"""
import json
import logging
import os
import threading
import time

import httpx

import geo
import guidance
import push
import routing
import sessions

URL = "https://generativelanguage.googleapis.com/v1beta/models/{}:generateContent"
MODELS = (os.getenv("AGENT_MODEL", "gemini-3.5-flash-lite"), "gemini-3.1-flash-lite")
MAX_ROUNDS = 4
BUDGET_S = 8
WALK_MPS = 1.3
FOLLOW_UP_S = 60
log = logging.getLogger("acoustic")

SYSTEM = """You are the voice of AcousticMaps, a walking guide for a blind person on a university campus.
Everything you write is spoken aloud through one earbud.
- Reply in at most two short sentences. Never mention anything visual (maps, screens, colors, lines).
- Use the tools for every place, distance and direction; never invent them. Say distances as the tools
  give them, in meters. Only say a direction (left, right, ahead, behind...) if a tool returned it, in the
  tool's words; never clock positions or compass points.
- If the user asks for a kind of place ("coffee", "food", "a bathroom"), pick the nearest one and start
  navigation right away. If they name a place that several places match (e.g. "the library"), ask one short
  question naming the nearest two instead. If they answer your question, start navigation to their choice.
- When you start navigation, say the place and distance, then the tool's start_sentence direction.
- "I'm lost" or "where am I": call trip_status, reassure them, say which way the route is, and offer a new route.
- If you can't help, say so plainly and suggest something they can say, like "take me to Malott Hall".
Right now: state={state}; destination={destination}; position known={has_pos}."""

TOOLS = [{"functionDeclarations": [
    {"name": "search_places", "description": "Find places near the user by name or kind (coffee, library, food, "
     "bathroom, bus stop...). Nearest first.",
     "parameters": {"type": "object", "properties": {
         "query": {"type": "string", "description": "a place name or a kind of place"},
         "radius_m": {"type": "integer", "description": "search radius in meters, default 800"}},
         "required": ["query"]}},
    {"name": "plan_route", "description": "Walking distance and time to a place from search_places, without starting.",
     "parameters": {"type": "object", "properties": {"place_id": {"type": "string"}}, "required": ["place_id"]}},
    {"name": "start_navigation", "description": "Start turn-by-turn walking navigation to a place from search_places.",
     "parameters": {"type": "object", "properties": {"place_id": {"type": "string"}}, "required": ["place_id"]}},
    {"name": "cancel_navigation", "description": "Stop the current navigation."},
    {"name": "trip_status", "description": "The current trip: destination, remaining distance and time, next "
     "instruction, and whether the user is off the route and which way it is."},
    {"name": "describe_surroundings", "description": "Named buildings and places within about 60 meters, "
     "with their direction from the user."},
]}]


def available():
    return bool(os.getenv("GEMINI_API_KEY")) and not routing.MOCK


def start(session_id, transcript):
    """Run reason() in the background; its answer arrives through push.notify."""
    threading.Thread(target=reason, args=(session_id, transcript), daemon=True).start()


def reason(session_id, transcript):
    s = sessions.get(session_id)
    s["agent_route"] = None
    t0 = time.monotonic()
    try:
        say = run(s, transcript)
    except Exception:
        log.exception("agent failed on %r", transcript)
        say = None
    if not say:
        say = fallback(s, transcript)
    log.info("%s agent %r -> %r (%.1f s)", session_id[:8], transcript, say, time.monotonic() - t0)
    s["agent_last"] = (time.monotonic(), transcript, say)
    finish(s, session_id, say)
    return say


def run(s, transcript):
    """The tool loop. Returns the spoken answer, or None."""
    key = os.getenv("GEMINI_API_KEY")
    if not key:
        return None
    dest = s["route"]["destination"]["name"] if s["route"] else "none"
    system = SYSTEM.format(state=s["before_agent"], destination=dest, has_pos=s["pos"] is not None)
    contents = [{"role": "user", "parts": [{"text": transcript}]}]
    last = s.get("agent_last")
    if last and time.monotonic() - last[0] < FOLLOW_UP_S:  # e.g. answering "Olin or Uris?"
        contents = [{"role": "user", "parts": [{"text": last[1]}]},
                    {"role": "model", "parts": [{"text": last[2]}]}] + contents
    deadline = time.monotonic() + BUDGET_S
    for _ in range(MAX_ROUNDS + 1):
        content = ask(key, system, contents, deadline)
        if content is None:
            return None
        contents.append(content)
        calls = [p["functionCall"] for p in content.get("parts", []) if "functionCall" in p]
        if not calls:
            text = " ".join(p["text"] for p in content.get("parts", []) if p.get("text")).strip()
            return text or None
        parts = []
        for call in calls:
            result = use_tool(s, call["name"], call.get("args") or {})
            log.info("  tool %s(%s) -> %s", call["name"], json.dumps(call.get("args") or {}), json.dumps(result)[:200])
            parts.append({"functionResponse": {"name": call["name"], "id": call.get("id"), "response": result}})
        contents.append({"role": "user", "parts": parts})
    return None


def ask(key, system, contents, deadline):
    for model in MODELS:
        left = deadline - time.monotonic()
        if left < 0.5:
            return None
        try:
            r = httpx.post(URL.format(model), headers={"x-goog-api-key": key}, timeout=left, json={
                "systemInstruction": {"parts": [{"text": system}]}, "contents": contents, "tools": TOOLS,
                "generationConfig": {"temperature": 0.2, "thinkingConfig": {"thinkingLevel": "minimal"}}})
            r.raise_for_status()
            return r.json()["candidates"][0]["content"]
        except (httpx.HTTPError, KeyError, IndexError, ValueError) as e:
            log.warning("agent model %s failed: %s", model, e)
    return None


def use_tool(s, name, args):
    try:
        if s["pos"] is None and name not in ("cancel_navigation", "trip_status"):
            return {"error": "the user's position isn't known yet"}
        return TOOL_FUNCS[name](s, **args)
    except Exception as e:
        log.exception("tool %s failed", name)
        return {"error": str(e)}


def where(s, lat, lng):
    return guidance.direction(s, geo.bearing_deg(s["pos"], (lat, lng)))


def search_places(s, query, radius_m=800):
    places = routing.search_places(query, s["pos"], int(radius_m))
    s["agent_places"] = {f"p{i + 1}": p for i, p in enumerate(places)}
    return {"places": [{"place_id": f"p{i + 1}", "name": p["name"], "category": p["category"],
                        "distance_m": guidance.round_m(p["distance_m"]), "direction": where(s, p["lat"], p["lng"])}
                       for i, p in enumerate(places)]}


def _route_to(s, place_id, polish):
    place = s.get("agent_places", {}).get(place_id)
    if place is None:
        return None, {"error": f"unknown place_id {place_id}; call search_places first"}
    route = routing.get_route(s["pos"], place, polish=polish)
    if route is None:
        return None, {"error": f"no walking route to {place['name']} right now"}
    return route, None


def plan_route(s, place_id):
    route, err = _route_to(s, place_id, polish=False)
    if err:
        return err
    turns = sum(1 for st in route["steps"] if st["turn"] != "arrive")
    return {"name": route["destination"]["name"], "distance_m": guidance.round_m(route["distance_m"]),
            "minutes": max(1, round(route["distance_m"] / WALK_MPS / 60)), "turns": turns}


def start_navigation(s, place_id):
    import handler  # handler imports this module
    route, err = _route_to(s, place_id, polish=True)
    if err:
        return err
    s["agent_route"] = route  # started in finish(), so the answer is spoken before the first instruction
    return {"started": True, "name": route["destination"]["name"],
            "distance_m": guidance.round_m(route["distance_m"]),
            "minutes": max(1, round(route["distance_m"] / WALK_MPS / 60)),
            "start_sentence": handler.start_sentence(s, route)}


def cancel_navigation(s):
    if s["route"] is None:
        return {"cancelled": False, "reason": "no trip in progress"}
    sessions.end_trip(s)
    return {"cancelled": True}


def trip_status(s):
    if s["route"] is None:
        return {"navigating": False, "state": s["before_agent"]}
    route = s["route"]
    step = route["steps"][s["step_i"]]
    status = {"navigating": True, "destination": route["destination"]["name"],
              "arrived": s["before_agent"] == "arrived",
              "remaining_m": guidance.round_m(guidance.remaining_m(s)),
              "minutes": max(1, round(guidance.remaining_m(s) / WALK_MPS / 60)),
              "next_instruction": guidance.turn_phrase(step),
              "next_instruction_in_m": guidance.round_m(step["along_m"] - s["progress_m"]),
              "off_route_m": round(s["off_m"])}
    if s["off_m"] > guidance.BACK_ON_M:
        target = geo.point_at(route["polyline"], route["cum"], s["raw_along_m"])
        status["on_route"] = False
        status["way_back_to_route"] = guidance.direction(s, geo.bearing_deg(s["pos"], target))
    else:
        status["on_route"] = True
        status["route_continues"] = guidance.direction(s, guidance.segment_bearing(s))
    return status


def describe_surroundings(s):
    return {"nearby": [{"name": p["name"], "distance_m": p["distance_m"], "direction": where(s, p["lat"], p["lng"])}
                       for p in routing.nearby(s["pos"])[:4]]}


TOOL_FUNCS = {f.__name__: f for f in (search_places, plan_route, start_navigation, cancel_navigation,
                                      trip_status, describe_surroundings)}


def fallback(s, transcript):
    """No usable answer from Gemini: the plain place search, so the user always hears something."""
    import handler
    place = routing.find_place(transcript, s["pos"]) if s["pos"] else None
    if place:
        route = routing.get_route(s["pos"], place)
        if route:
            sessions.start_trip(s, route)
            return handler.start_sentence(s, route)
    return "Sorry, I didn't understand. You can say a place, like Malott Hall."


def finish(s, session_id, say):
    import handler
    if s.get("agent_route"):
        sessions.start_trip(s, s.pop("agent_route"))
    if s["state"] == "thinking":
        s["state"] = s["before_agent"] if s["before_agent"] in ("navigating", "off_route") and s["route"] else "idle"
    s["last_say"], s["last_say_t"] = say, time.monotonic()
    route, route_line = handler.route_payload(s)
    push.notify(session_id, say=say, haptic="tick" if route else None, state=s["state"],
                route=route, route_line=route_line)


if __name__ == "__main__":
    import argparse

    from dotenv import load_dotenv

    load_dotenv()
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)
    p = argparse.ArgumentParser()
    p.add_argument("say", nargs="+")
    p.add_argument("--at", default="42.449626,-76.481794", help="lat,lng (default PSB)")
    p.add_argument("--heading", type=float, default=180)
    p.add_argument("--trip", help="start a trip to this place first (to test trip questions)")
    args = p.parse_args()
    s = sessions.get("cli")
    s.update(pos=tuple(float(x) for x in args.at.split(",")), heading=args.heading, is_new=False)
    if args.trip:
        sessions.start_trip(s, routing.get_route(s["pos"], routing.find_place(args.trip, s["pos"])))
    s["before_agent"] = s["state"]
    print("SAY:", reason("cli", " ".join(args.say)))
