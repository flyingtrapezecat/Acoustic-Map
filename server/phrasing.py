"""Gemini rewrites a trip's turn instructions into natural speech, once when the trip starts.
The rules still decide what to say and when; Gemini only rewords, and every phrase is checked
(sides, stairs, crossings, no numbers) before it's used. Any failure keeps the rule wording."""
import json
import os
import re
import time

import httpx

import cache
import guidance

URL = "https://generativelanguage.googleapis.com/v1beta/models/{}:generateContent"
MODELS = (os.getenv("GEMINI_MODEL", "gemini-3.5-flash-lite"), "gemini-3.1-flash-lite")
BUDGET_S = 5
MAX_LEN = 110
MUST_MENTION = {"stairs": "stair", "archway": "arch", "crossing": "cross"}
INVENTED = {"up", "down", "uphill", "downhill", "steep", "careful", "carefully", "slope", "ramp", "door"}  # facts we never have

PROMPT = """You write spoken walking directions for a blind pedestrian, heard through one earbud.
Each step has the facts and a stiff draft built by rules. Rewrite each into what a friendly human guide
walking beside them would say: natural, calm, short. Keep every fact; add none.
Rules:
- Every turn keeps its side (left/right). Keep "slightly"/"sharp" contrasts (you may say "the gentle right").
- Mention every stairs, archway and street crossing in the step, in order. Keep building and street names exactly.
- No numbers or distances (the app adds "In 40 meters," itself).
- "ahead": continues the sentence "In 40 meters, ..." so start lowercase, no final period.
- "now": a full sentence said at the spot. Include "now", unless the step starts with a street crossing:
  then say to cross when it's safe.
- At most 15 words each.
Examples of the style:
- draft "turn left, then right" -> ahead "turn left, then right straight after", now "Turn left now, then right straight after."
- draft "cross the street, then left toward Lyon Hall, then keep right" -> ahead "cross the street, turn left toward
  Lyon Hall and keep right", now "Cross the street when it's safe, then go left toward Lyon Hall and keep right."
- draft "turn slightly right, not the sharp right" -> ahead "take the gentle right, not the sharp right",
  now "Take the gentle right now, not the sharp right."
Return JSON: {"steps": [{"i": <step index>, "ahead": "...", "now": "..."}]}

Steps:
"""


def polish(route, ask_gemini=True):
    """Add Gemini's wording to the route's steps (say_ahead / say_now). Returns how many steps got it.
    Each step's wording is cached by its facts, so repeat trips (the demo) need no Gemini call.
    ask_gemini=False only uses the cache (reroutes must be instant)."""
    steps = [st for st in route["steps"] if st["turn"] != "arrive"]
    keys = [{"facts": fact(st), "draft": guidance.turn_phrase(st, polished=False)} for st in steps]
    todo = []
    for st, k in zip(steps, keys):
        hit = cache.get("phrases", k)
        if hit:
            st["say_ahead"], st["say_now"] = hit["ahead"], hit["now"]
        else:
            todo.append((st, k))
    key = os.getenv("GEMINI_API_KEY")
    if ask_gemini and key and todo:
        facts = [{"i": i, **k["facts"], "draft": k["draft"]} for i, (_, k) in enumerate(todo)]
        reply = ask(key, PROMPT + json.dumps(facts, indent=1))
        for item in (reply or {}).get("steps", []):
            i = item.get("i")
            if not isinstance(i, int) or not 0 <= i < len(todo):
                continue
            st, k = todo[i]
            ahead, now = clean(item.get("ahead"), lower=True), clean(item.get("now"))
            if ok(ahead, st) and ok(now, st, now=True):
                st["say_ahead"], st["say_now"] = ahead, now
                cache.put("phrases", k, {"ahead": ahead, "now": now})
    return sum(1 for st in steps if st.get("say_now"))


def fact(step):
    parts = [step] + step.get("then", [])
    return {"actions": [{k: v for k, v in p.items() if k in ("turn", "which", "street", "path", "toward") and v}
                        for p in parts]}


def ask(key, prompt):
    deadline = time.monotonic() + BUDGET_S
    for model in MODELS:
        left = deadline - time.monotonic()
        if left <= 0.5:
            break
        try:
            r = httpx.post(URL.format(model), headers={"x-goog-api-key": key}, timeout=left, json={
                "contents": [{"parts": [{"text": prompt}]}],
                "generationConfig": {"responseMimeType": "application/json", "temperature": 0.3,
                                     "thinkingConfig": {"thinkingLevel": "minimal"}}})
            r.raise_for_status()
            return json.loads(r.json()["candidates"][0]["content"]["parts"][0]["text"])
        except (httpx.HTTPError, KeyError, IndexError, ValueError):
            continue
    return None


def clean(text, lower=False):
    if not isinstance(text, str):
        return None
    text = " ".join(text.split()).strip()
    if lower:
        text = text.rstrip(".")
        text = text[:1].lower() + text[1:]
    elif text and text[-1] not in ".!":
        text += "."
    return text


def sides(text):
    return re.findall(r"\b(left|right)\b", text.lower())


def ok(text, step, now=False):
    """Reject anything that changes the facts: numbers, missing or extra sides, a dropped feature."""
    if not text or len(text) > MAX_LEN or re.search(r"\d", text):
        return False
    rule = guidance.turn_phrase(step, now=now, polished=False)
    if set(sides(text)) != set(sides(rule)):
        return False
    lowered = text.lower()
    if (set(re.findall(r"[a-z]+", lowered)) & INVENTED) - set(re.findall(r"[a-z]+", rule.lower())):
        return False
    for part in [step] + step.get("then", []):
        if part["turn"] in MUST_MENTION and MUST_MENTION[part["turn"]] not in lowered:
            return False
        for name in (part.get("toward"), part.get("street")):
            if name and name.lower() not in lowered:
                return False
    if now and step["turn"] == "crossing":
        return "safe" in lowered
    return not now or "now" in lowered
