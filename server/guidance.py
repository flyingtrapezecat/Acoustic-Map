"""Decides what to say each tick while navigating (checks in docs/navigation.md)."""
import time

import geo

ARRIVE_M = 15
NOW_M = 10
AHEAD_M = 40
REASSURE_S = 45
REASSURE_PROGRESS_M = 20

BACK_M = 25
WINDOW_AHEAD_M = 60
MAX_STEP_M = 20
OFF_LIMIT_M = 20


def turn_phrase(step):
    if step["turn"] == "arrive":
        return "arrive at your destination"
    phrase = f"turn {step['turn'].replace('_', ' ')}"
    if step["turn"] == "straight":
        phrase = "continue straight"
    if step.get("street"):
        phrase += f" onto {step['street']}"
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


def next_instruction(s):
    """(say, haptic) for this tick, or (None, None)."""
    track(s)
    passed = pass_turns(s)

    route = s["route"]
    step = route["steps"][s["step_i"]]
    to_turn = step["along_m"] - s["progress_m"]
    dest = route["destination"]
    key = s["step_i"]

    if (remaining_m(s) <= ARRIVE_M
            or geo.distance_m(s["pos"], (dest["lat"], dest["lng"])) <= ARRIVE_M):
        s["state"] = "arrived"
        return f"You have arrived at {dest['name']}.", "arrived"

    if step["turn"] != "arrive":
        if to_turn <= NOW_M and f"{key}:now" not in s["announced"]:
            s["announced"].update({f"{key}:now", f"{key}:ahead"})
            return f"{turn_phrase(step).capitalize()} now.", turn_haptic(step)
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
