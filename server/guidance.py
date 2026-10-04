"""Decides what to say each tick while navigating (checks in docs/navigation.md)."""
import time

import geo
import routing
import sessions

ARRIVE_M = 15
DOOR_SAY_M = 6
VIA = {"archway": ", through the archway", "stairs": ", by the stairs", "crossing": ", across the street"}
NOW_M = 10
AHEAD_M = 40
REASSURE_S = 45
REASSURE_PROGRESS_M = 20

BACK_M = 25
WINDOW_AHEAD_M = 60
MAX_STEP_M = 20
OFF_LIMIT_M = 20

BACK_ON_M = 12
BAD_TICKS = 3
GOOD_TICKS = 2
CORRECT_EVERY_S = (15, 30, 45)
CLOSING_IN_M = 5
MOVING_MPS = 0.5
WRONG_WAY_BACK_M = 8
FORWARD_AGAIN_M = 5
WEAK_GPS_S = 10
REROUTE_M = 40
REROUTE_AFTER_S = 30
REROUTE_EVERY_S = 15


PHRASES = {"arrive": "arrive at your destination", "straight": "continue straight",
           "slight_left": "keep left", "slight_right": "keep right", "uturn": "make a U-turn",
           "archway": "go through the archway", "stairs": "take the stairs", "crossing": "cross the street"}
# when two paths leave on the same side: (what to say, the contrast added at the end)
WHICH = {"slight": ("turn slightly {side}", ", not the sharp {side}"),
         "sharp": ("turn sharp {side}", ", not the slight {side}"),
         "middle": ("take the middle path on your {side}", "")}
NOW_PHRASES = {"crossing": "street crossing here, cross when it's safe"}


def one_phrase(step, now=False):
    if now and step["turn"] in NOW_PHRASES:
        return NOW_PHRASES[step["turn"]]
    phrase = PHRASES.get(step["turn"], f"turn {step['turn'].replace('_', ' ')}")
    side = "left" if "left" in step["turn"] else "right"
    which = WHICH.get(step.get("which"))
    if which:
        phrase = which[0].format(side=side)
    if now:
        phrase += " now"
    if step.get("path"):
        phrase += f" onto {step['path']}"
    elif step.get("street"):
        phrase += f" onto {step['street']}"
    if step.get("toward"):
        phrase += f" toward {step['toward']}"
    if which and which[1]:
        phrase += which[1].format(side=side)
    return phrase


def turn_phrase(step, now=False, polished=True):
    """'turn left', or for steps said together 'turn left, then right' ('turn left now, then right').
    Uses Gemini's wording (phrasing.py) when the step has it."""
    if polished and step.get("say_now" if now else "say_ahead"):
        return step["say_now" if now else "say_ahead"].rstrip(".")
    phrase = one_phrase(step, now)
    for nxt in step.get("then", []):
        phrase += ", then " + one_phrase(nxt).removeprefix("turn ")
    return phrase


def turn_haptic(step):
    if "left" in step["turn"]:
        return "turn_left"
    if "right" in step["turn"]:
        return "turn_right"
    return "tick"


def round_m(meters):
    return max(10, int(round(meters / 10) * 10))


def remaining_m(s):
    return max(0.0, s["route"]["distance_m"] - s["progress_m"])


def track(s):
    """Move progress forward along the route from a fresh, accurate fix."""
    route, progress = s["route"], s["progress_m"]
    along, off, seg_i = geo.locate(s["pos"], route["polyline"], route["cum"],
                                   max(0.0, progress - BACK_M), progress + WINDOW_AHEAD_M,
                                   prefer=progress)
    s["raw_along_m"], s["off_m"], s["seg_i"] = along, off, seg_i
    if off <= OFF_LIMIT_M:
        s["progress_m"] = min(max(progress, along), progress + MAX_STEP_M)


def pass_turns(s):
    """Advance step_i past turns behind progress. The final arrive step is left to the arrival check."""
    steps, passed = s["route"]["steps"], False
    while s["step_i"] < len(steps) - 1 and s["progress_m"] >= steps[s["step_i"]]["along_m"]:
        s["step_i"] += 1
        passed = True
    return passed


def facing(s):
    """Direction the user is going (course while walking), else where the phone points."""
    if s["course"] is not None and (s["speed"] or 0) > MOVING_MPS:
        return s["course"]
    return s["heading"] if s["heading"] is not None else s["course"]


def direction(s, bearing):
    face = facing(s)
    if face is None:
        return f"to the {geo.compass_word(bearing)}"
    return geo.relative_direction(face, bearing)


def segment_bearing(s):
    poly, i = s["route"]["polyline"], s["seg_i"]
    return geo.bearing_deg(poly[i], poly[i + 1])


def going_backward(s):
    """Positions only: iOS course lags and repeats stale values at walking speed (walk 4)."""
    return ((s["speed"] or 0) > MOVING_MPS and s["off_m"] <= OFF_LIMIT_M
            and s["raw_along_m"] < s["progress_m"] - WRONG_WAY_BACK_M)


def correction_say(s):
    if s["correction"] == "back":
        return "You're heading the wrong way. Turn around."
    route = s["route"]
    target = geo.point_at(route["polyline"], route["cum"], s["raw_along_m"])
    return (f"You've left the route. The path is {direction(s, geo.bearing_deg(s['pos'], target))}, "
            f"{round_m(s['off_m'])} meters.")


def start_correction(s, kind):
    now = time.monotonic()
    s.update(correction=kind, state="off_route", correction_t=now, off_since_t=now,
             good_ticks=0, bad_off=0, bad_wrong=0, min_raw_m=s["raw_along_m"],
             correction_repeats=0, correction_off_m=s["off_m"])
    return correction_say(s), "off_route"


def correcting(s):
    """While off route or going the wrong way: confirm recovery, reroute, or repeat the correction."""
    now = time.monotonic()
    s["min_raw_m"] = min(s["min_raw_m"], s["raw_along_m"])
    if s["correction"] == "off":
        ok = s["off_m"] <= BACK_ON_M
    else:
        ok = s["raw_along_m"] >= s["min_raw_m"] + FORWARD_AGAIN_M and s["off_m"] <= OFF_LIMIT_M
    s["good_ticks"] = s["good_ticks"] + 1 if ok else 0

    if s["good_ticks"] >= GOOD_TICKS:
        s.update(correction=None, state="navigating", good_ticks=0, reassured_at_m=s["progress_m"])
        heading_on = direction(s, segment_bearing(s))
        then = "Keep going straight." if heading_on == "straight ahead" else f"Follow it {heading_on}."
        return f"You're back on route. {then}", "tick"

    if s["correction"] == "back" and s["off_m"] > OFF_LIMIT_M:
        s["bad_off"] += 1
        if s["bad_off"] >= BAD_TICKS:
            return start_correction(s, "off")

    if (s["correction"] == "off" and not routing.MOCK
            and (s["off_m"] > REROUTE_M or now - s["off_since_t"] > REROUTE_AFTER_S)
            and now - s["last_reroute_t"] > REROUTE_EVERY_S):
        s["last_reroute_t"] = now
        try:
            route = routing.get_route(s["pos"], s["route"]["destination"], polish=False)
        except Exception:
            route = None
        if route:
            sessions.start_trip(s, route)
            return f"Finding a new route. {round_m(route['distance_m'])} meters to {route['destination']['name']}.", "tick"

    wait = CORRECT_EVERY_S[min(s["correction_repeats"], len(CORRECT_EVERY_S) - 1)]
    if now - s["correction_t"] < wait:
        return None, None
    s["correction_t"] = now
    if s["correction"] == "off" and s["off_m"] < s["correction_off_m"] - CLOSING_IN_M:
        s["correction_off_m"] = s["off_m"]  # heading back already: stay quiet
        return None, None
    s["correction_repeats"] += 1
    s["correction_off_m"] = s["off_m"]
    return correction_say(s), "off_route"


def arrival_say(s, dest):
    """Which side the building is on, and where its door is if it's not right here."""
    say = f"You have arrived at {dest['name']}."
    face = facing(s)
    if face is None:
        face = segment_bearing(s)
    if dest.get("center"):
        where = geo.relative_direction(face, geo.bearing_deg(s["pos"], dest["center"]))
        say += f" It's {where}."
    door = (dest["lat"], dest["lng"])
    via = VIA.get(dest.get("via"), "")
    if via or geo.distance_m(s["pos"], door) >= DOOR_SAY_M:
        say += f" The entrance is {geo.relative_direction(face, geo.bearing_deg(s['pos'], door))}{via}."
    return say


def weak_gps(s):
    """Called for fresh fixes too inaccurate to track. Says so once per weak spell."""
    now = time.monotonic()
    if s["weak_gps_since"] is None:
        s["weak_gps_since"] = now
    if not s["weak_said"] and now - s["weak_gps_since"] >= WEAK_GPS_S:
        s["weak_said"] = True
        return "GPS signal is weak. Keep going carefully.", None
    return None, None


def next_instruction(s):
    """(say, haptic) for this tick, or (None, None)."""
    s["weak_gps_since"], s["weak_said"] = None, False
    track(s)
    passed = pass_turns(s)

    route = s["route"]
    step = route["steps"][s["step_i"]]
    to_turn = step["along_m"] - s["progress_m"]
    dest = route["destination"]
    key = s["step_i"]

    if (remaining_m(s) <= ARRIVE_M
            or geo.distance_m(s["pos"], (dest["lat"], dest["lng"])) <= ARRIVE_M):
        s.update(state="arrived", correction=None)
        return arrival_say(s, dest), "arrived"

    if s["correction"]:
        return correcting(s)

    s["bad_off"] = s["bad_off"] + 1 if s["off_m"] > OFF_LIMIT_M else 0
    s["bad_wrong"] = s["bad_wrong"] + 1 if going_backward(s) else 0
    if s["bad_off"] >= BAD_TICKS:
        return start_correction(s, "off")
    if s["bad_wrong"] >= BAD_TICKS:
        return start_correction(s, "back")

    if step["turn"] != "arrive":
        if to_turn <= NOW_M and f"{key}:now" not in s["announced"]:
            s["announced"].update({f"{key}:now", f"{key}:ahead"})
            phrase = turn_phrase(step, now=True)
            return f"{phrase[0].upper()}{phrase[1:]}.", turn_haptic(step)
        # just after a turn, announce a close next turn right away instead of "continue"
        if (to_turn <= AHEAD_M or (passed and to_turn <= AHEAD_M + 15)) \
                and f"{key}:ahead" not in s["announced"]:
            s["announced"].add(f"{key}:ahead")
            return f"In {round_m(to_turn)} meters, {turn_phrase(step)}.", "tick"

    if passed and to_turn > AHEAD_M + 15:
        if step["turn"] == "arrive":
            return f"Continue {round_m(to_turn)} meters to {dest['name']}.", None
        return f"Continue straight for {round_m(to_turn)} meters.", None

    if (time.monotonic() - s["last_say_t"] > REASSURE_S
            and to_turn > AHEAD_M + 15
            and s["off_m"] <= OFF_LIMIT_M
            and s["progress_m"] >= s["reassured_at_m"] + REASSURE_PROGRESS_M):
        s["reassured_at_m"] = s["progress_m"]
        if step["turn"] == "arrive":
            return f"Still on route. {round_m(to_turn)} meters to {dest['name']}.", None
        return f"Still on route. {round_m(to_turn)} meters to the next turn.", None

    return None, None
