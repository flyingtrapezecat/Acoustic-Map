"""Decides what to say each tick while navigating."""

def turn_phrase(step):
    """'turn left onto Bancroft Way', 'arrive at your destination', ..."""
    if step["turn"] == "arrive":
        return "arrive at your destination"
    phrase = f"turn {step['turn'].replace('_', ' ')}"
    if step["turn"] == "straight":
        phrase = "continue straight"
    if step.get("street"):
        phrase += f" onto {step['street']}"
    return phrase


def next_instruction(s):
    """(say, haptic) for this tick. Step 3: always silent."""
    return None, None
