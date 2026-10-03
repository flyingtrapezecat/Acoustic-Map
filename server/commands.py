"""Turns what user said into action with plain phrase matching"""
CANCEL = {"cancel", "stop", "stop navigation", "cancel navigation", "end route", "end navigation"}
REPEAT = {"repeat", "repeat that", "say again", "say that again", "what", "pardon", "sorry"}
STATUS_STARTS = ("where am i", "how far", "how much further", "how much longer", "are we there")
GO_PREFIXES = ("take me to", "navigate to", "directions to", "walk me to", "walk to",
               "i want to go to", "go to", "find")


def parse(transcript):
    """Returns (action, arg): ("go", place) | ("cancel", None) | ("repeat", None)
    | ("status", None) | ("empty", None)."""
    text = (transcript or "").lower().strip().rstrip(".!?").strip()
    if not text:
        return "empty", None
    # Whole-phrase matches only, so "take me to the bus stop" isn't a cancel.
    if text in CANCEL:
        return "cancel", None
    if text in REPEAT:
        return "repeat", None
    if text.startswith(STATUS_STARTS):
        return "status", None
    for prefix in GO_PREFIXES:
        if text.startswith(prefix + " "):
            return "go", text[len(prefix) + 1:]
    return "go", text