"""Find places and walking routes.
ROUTING_MOCK=1 reads ROUTING_MOCK_FILE; ROUTING_MOCK=0 uses OSRM foot routing (OpenStreetMap)."""
import json
import logging
import os
import re
import time
from pathlib import Path

import httpx

import cache
import geo
import paths
import phrasing

log = logging.getLogger("acoustic")

MOCK = os.getenv("ROUTING_MOCK", "1") == "1"
ROUTES_DIR = Path(__file__).parent / "mock" / "routes"
SAVED_START_M = 80   # a saved route is only used if it starts this close to the user
MOCK_FILE = Path(os.getenv("ROUTING_MOCK_FILE") or Path(__file__).parent / "mock" / "demo_route.json")
OSRM_URL = ("https://routing.openstreetmap.de/routed-foot/route/v1/driving/"
            "{0[1]},{0[0]};{1[1]},{1[0]}?overview=full&geometries=geojson&steps=true")
TURNS = {"left", "right", "slight left", "slight right", "sharp left", "sharp right", "uturn"}
START_SKIP_M = 35
MERGE_M = 15         # steps closer than this are said together: "turn left, then right"
ARRIVE_NEAR_M = 15   # features this close to the end are part of the arrival sentence
NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"
HEADERS = {"User-Agent": "AcousticMaps/0.1 (hackathon)"}
SEARCH_BOX_DEG = 0.015  # about 1.5 km around the user
SKIP_TYPES = {"bicycle_parking", "parking", "bench", "waste_basket"}

# demo destinations: no network needed, and spoken short names work ("take me to Olin").
# lat/lng is the building's center; doors are the entrances to route to (the nearest one wins).
PSB = {"name": "Physical Sciences Building", "lat": 42.44987, "lng": -76.481791,
       "doors": [[42.449626, -76.481794], [42.449684, -76.482135]]}
KNOWN_PLACES = {
    ("malott",): {"name": "Malott Hall", "lat": 42.448186, "lng": -76.48019, "doors": [[42.44847, -76.480097]]},
    ("psb",): PSB,
    ("physical", "sciences"): PSB,
    ("flora", "rose"): {"name": "Flora Rose House", "lat": 42.447918, "lng": -76.488786,
                        "doors": [[42.44783, -76.488893]]},
    ("olin",): {"name": "Olin Library", "lat": 42.447823, "lng": -76.484281, "doors": [[42.447972, -76.484776]]},
    ("uris",): {"name": "Uris Library", "lat": 42.447729, "lng": -76.485286},
    ("gates",): {"name": "Gates Hall", "lat": 42.444968, "lng": -76.480864, "doors": [[42.444998, -76.481389]]},
    ("duffield",): {"name": "Duffield Hall", "lat": 42.444535, "lng": -76.482598},
    ("willard", "straight"): {"name": "Willard Straight Hall", "lat": 42.446466, "lng": -76.485605},
}
MAX_DOORS = 4
FILLER = {"a", "an", "the", "some", "somewhere", "place", "places", "to", "get", "i", "can", "nearest", "closest",
          "near", "me", "any", "find", "where", "is", "go", "for", "of", "nearby", "good"}
# kinds of place the agent can ask for, as OpenStreetMap tags
CATEGORIES = {
    ("coffee", "cafe", "café"): '[amenity=cafe][name]',
    ("food", "eat", "lunch", "dinner", "restaurant", "hungry"): '[amenity~"^(restaurant|fast_food|cafe)$"][name]',
    ("library", "libraries"): '[amenity=library][name]',
    ("bathroom", "restroom", "toilet", "toilets"): '[amenity=toilets]',
    ("water", "fountain"): '[amenity=drinking_water]',
    ("bus", "stop"): '[highway=bus_stop]',
    ("atm", "cash"): '[amenity=atm]',
    ("pharmacy",): '[amenity=pharmacy]',
    ("store", "grocery", "shop"): '[shop][name]',
}

_last_search_t = 0.0


def _load_mock():
    with MOCK_FILE.open() as f:
        return json.load(f)


def find_place(text, near):
    """Spoken destination -> {"name", "lat", "lng"}, or None if nothing matches."""
    if MOCK:
        return _load_mock()["destination"]
    place = known_place(text)
    if place:
        return place
    words = set(re.sub(r"[^a-z0-9 ]", " ", text.lower()).split())
    key = [" ".join(sorted(words)), round(near[0], 2), round(near[1], 2)]  # same words, same ~1 km area
    place = cache.get("places", key)
    if place is None:
        place = search(text, near)
        if place:
            cache.put("places", key, place)
    return place


def known_place(text):
    """A demo destination named in the text ("take me to Olin"), or None."""
    words = set(re.sub(r"[^a-z0-9 ]", " ", (text or "").lower()).split())
    for alias, place in KNOWN_PLACES.items():
        if set(alias) <= words:
            return place
    return None


def search_places(query, near, radius_m=800, limit=5):
    """Places matching a name or a kind of place ("coffee"), nearest first, for the agent.
    Known demo places come first. Each: {name, lat, lng, category, distance_m, doors?}."""
    known = known_place(query)
    found = [dict(known, category="building", known=True)] if known else []
    words = set(re.sub(r"[^a-z0-9 ]", " ", query.lower()).split()) - FILLER
    tags = next((tag for keys, tag in CATEGORIES.items() if words & set(keys)), None)
    kind_only = tags and all(any(w in keys for keys in CATEGORIES) for w in words)
    lat, lng = round(near[0], 3), round(near[1], 3)  # rounded so nearby searches share the cache
    selectors = [] if not words else [f"nwr(around:{radius_m},{lat},{lng}){tags}"] if kind_only else \
        [f"nwr(around:{radius_m},{lat},{lng})" + "".join(f'[name~"{re.escape(w)}",i]' for w in sorted(words))] + \
        ([f"nwr(around:{radius_m},{lat},{lng}){tags}"] if tags else [])
    for selector in selectors:
        for e in paths.overpass(f"[out:json][timeout:6];{selector};out center tags;", timeout=6, waits=(0,)) or []:
            where = e.get("center") or e
            if "lat" not in where:
                continue
            found.append({"name": e["tags"].get("name") or e["tags"].get("amenity", "place").replace("_", " "),
                          "lat": where["lat"], "lng": where["lon"], "osm": [e["type"], e["id"]],
                          "category": e["tags"].get("amenity") or e["tags"].get("shop")
                                      or e["tags"].get("building") or "place"})
        if len(found) > (1 if known else 0):
            break
    for place in found:
        place["distance_m"] = round(geo.distance_m(near, (place["lat"], place["lng"])))
    best = {}
    for place in sorted(found, key=lambda p: (not p.get("known"), p["distance_m"])):
        if place["distance_m"] <= radius_m * 1.5:
            best.setdefault(place["name"], place)
    return list(best.values())[:limit]


def nearby(near, radius_m=60):
    """Named buildings and places around the user, nearest first: [{name, lat, lng, distance_m}]."""
    lat, lng = round(near[0], 4), round(near[1], 4)
    elements = paths.overpass(f'[out:json][timeout:6];nwr(around:{radius_m},{lat},{lng})[name]'
                              f'[~"^(building|amenity|shop|leisure|tourism)$"~"."];out center tags;',
                              timeout=6, waits=(0,)) or []
    best = {}
    for e in elements:
        where = e.get("center") or e
        if "lat" in where:
            d = round(geo.distance_m(near, (where["lat"], where["lon"])))
            name = e["tags"]["name"]
            if name not in best or d < best[name]["distance_m"]:
                best[name] = {"name": name, "lat": where["lat"], "lng": where["lon"], "distance_m": d}
    return sorted(best.values(), key=lambda p: p["distance_m"])


def search(text, near):
    """Nominatim search near the user; the closest match, or None."""
    global _last_search_t
    time.sleep(max(0.0, 1.0 - (time.monotonic() - _last_search_t)))  # Nominatim allows 1 request/s
    _last_search_t = time.monotonic()
    lat, lng, d = near[0], near[1], SEARCH_BOX_DEG
    try:
        r = httpx.get(NOMINATIM_URL, headers=HEADERS, timeout=5, params={
            "q": text, "format": "jsonv2", "limit": 5, "bounded": 1,
            "viewbox": f"{lng - d},{lat + d},{lng + d},{lat - d}"})
        r.raise_for_status()
    except httpx.HTTPError as e:
        log.warning("Nominatim failed for %r: %s", text, e)
        return None
    hits = [{"name": h["name"] or h["display_name"].split(",")[0],
             "lat": float(h["lat"]), "lng": float(h["lon"]), "osm": (h["osm_type"], h["osm_id"])}
            for h in r.json() if h["type"] not in SKIP_TYPES]
    best = min(hits, key=lambda h: geo.distance_m(near, (h["lat"], h["lng"])), default=None)
    if best:
        best["doors"] = doors(*best.pop("osm"))
    return best


def doors(osm_type, osm_id):
    """Entrances mapped on an OpenStreetMap building, [[lat, lng], ...] (often none)."""
    if osm_type not in ("way", "relation"):
        return []
    elements = paths.overpass(f"[out:json][timeout:10];{osm_type}({osm_id});node(w)[entrance];out;")
    return [[e["lat"], e["lon"]] for e in elements or []]


def get_route(start, place, polish=True):
    """Walking route from start (lat, lng) to place (a find_place result), ending at its nearest door.
    polish=False uses only Gemini wording already in the cache (reroutes need to be instant)."""
    if MOCK:
        return prepare(_load_mock())
    center = place.get("center") or [place["lat"], place["lng"]]
    if "doors" not in place and place.get("osm"):
        place["doors"] = doors(*place["osm"])
    doors_ = place.get("doors") or [[place["lat"], place["lng"]]]
    best = None
    for door in doors_[:MAX_DOORS]:
        dest = {"name": place["name"], "lat": door[0], "lng": door[1], "center": center}
        try:
            route = osrm_route(start, dest)
        except httpx.HTTPError as e:
            log.warning("OSRM failed for %s: %s", place["name"], e)
            continue
        if route and (best is None or route["distance_m"] < best["distance_m"]):
            best = route
    if best is None:
        return saved_route(start, place)
    describe(best)
    phrasing.polish(best, ask_gemini=polish)
    return best


def saved_route(start, place):
    """When OSRM is down: a saved route (mock/routes/*.json) to the same place that starts near the user."""
    for path in sorted(ROUTES_DIR.glob("*.json")):
        route = json.loads(path.read_text())
        if (route.get("destination", {}).get("name") == place["name"]
                and geo.distance_m(start, route["polyline"][0]) <= SAVED_START_M):
            log.warning("using saved route %s", path.name)
            return prepare(route)
    return None


def osrm_route(start, dest):
    r = httpx.get(OSRM_URL.format(start, (dest["lat"], dest["lng"])), timeout=5)
    r.raise_for_status()
    data = r.json()
    if data.get("code") != "Ok" or not data.get("routes"):
        return None
    return from_osrm(data["routes"][0], dest)


def from_osrm(osrm, dest):
    """OSRM route -> our route shape. Keeps only real turns, plus a final arrive step."""
    polyline = [[lat, lng] for lng, lat in osrm["geometry"]["coordinates"]]
    steps = []
    for st in osrm["legs"][0]["steps"]:
        m = st["maneuver"]
        if m["type"] in ("depart", "arrive") or m.get("modifier") not in TURNS:
            continue
        x = st["intersections"][0]
        in_b = (x["bearings"][x["in"]] + 180) % 360 if "in" in x else m["bearing_before"]
        others = [b for i, b in enumerate(x["bearings"]) if i not in (x.get("in"), x.get("out"))]
        # a slight turn with no other path near straight ahead is just the path bending
        if m["modifier"].startswith("slight") and not any(abs(geo.angle_diff(in_b, b)) <= 45 for b in others):
            continue
        steps.append({"lat": m["location"][1], "lng": m["location"][0],
                      "turn": m["modifier"].replace(" ", "_"), "street": st.get("name", ""),
                      "in_bearing": in_b, "out_bearing": m["bearing_after"], "other_bearings": others})
    end = polyline[-1]
    steps.append({"lat": end[0], "lng": end[1], "turn": "arrive", "street": ""})
    route = prepare({"destination": dest, "polyline": polyline, "steps": steps})

    # a turn right after the start is OSRM walking out of the building: start the route at that corner
    while len(route["steps"]) > 1 and route["steps"][0]["along_m"] < START_SKIP_M:
        route = trim_start(route, route["steps"].pop(0)["along_m"])
    return finish(route)


def describe(route):
    """Add what the paths are like: stairs, archways, crossings, and which branch to take at forks."""
    ways = paths.fetch_ways(route["polyline"])
    if not ways:
        return route
    steps = route["steps"]
    buildings = paths.fetch_ways(route["polyline"], 'way[building][name]') or []
    for i, step in enumerate(steps):
        if "in_bearing" not in step:
            continue
        if step["turn"].startswith("slight"):
            step["path"] = paths.branch_note(ways, (step["lat"], step["lng"]), step["out_bearing"],
                                             step["other_bearings"], step["in_bearing"])
        else:
            step["which"] = paths.which_one(step["in_bearing"], step["out_bearing"], step["other_bearings"])
        next_along = steps[i + 1]["along_m"] if i + 1 < len(steps) else route["distance_m"]
        step["toward"] = paths.toward(route, step, buildings, next_along)
    end = route["distance_m"]
    for along, kind in paths.features(route, ways):
        if end - along <= ARRIVE_NEAR_M:
            route["destination"]["via"] = kind  # "the entrance is ahead, through the archway"
            continue
        p = geo.point_at(route["polyline"], route["cum"], along)
        steps.append({"lat": p[0], "lng": p[1], "turn": kind, "street": "", "along_m": along})
    steps.sort(key=lambda st: st["along_m"])
    return finish(route)


def finish(route):
    """Merge steps too close to announce separately, then set each step's leg distance."""
    merged = []
    for step in route["steps"]:
        prev = merged[-1] if merged else None
        if prev and prev["turn"] != "arrive" and step["turn"] != "arrive" \
                and step["along_m"] - prev["along_m"] < MERGE_M:
            prev.setdefault("then", []).extend([step] + step.pop("then", []))
        else:
            merged.append(step)
    route["steps"] = merged
    prev = 0.0
    for step in merged:
        step["distance_m"] = round(step["along_m"] - prev, 1)
        prev = step["along_m"]
    return route


def trim_start(route, along):
    """Cut the first `along` meters off the route."""
    poly, cum = route["polyline"], route["cum"]
    start = list(geo.point_at(poly, cum, along))
    route["polyline"] = [start] + [p for p, c in zip(poly, cum) if c > along + 0.5]
    return prepare(route)


def prepare(route):
    """Add what route tracking needs: cumulative distances, and each step's distance along the route.
    Steps are located in order, each searching forward from the previous one,
    so a route that passes the same corner twice still gets the right order."""
    poly, cum = route["polyline"], geo.cumulative_m(route["polyline"])
    route["cum"] = cum
    route["distance_m"] = cum[-1]
    lo = 0.0
    for step in route["steps"]:
        along, _, _ = geo.locate((step["lat"], step["lng"]), poly, cum, lo)
        step["along_m"] = along
        lo = along
    return route


def warm(start, names):
    """Fill the cache for demo trips from `start`: places, paths, landmarks and Gemini wording."""
    for name in names:
        t0 = time.monotonic()
        place = find_place(name, start)
        route = get_route(start, place) if place else None
        if route is None:
            print(f"  {name}: no route")
            continue
        steps = [st for st in route["steps"] if st["turn"] != "arrive"]
        print(f"  {place['name']}: {route['distance_m']:.0f} m, {len(steps)} steps, "
              f"{sum(1 for st in steps if st.get('say_now'))} with Gemini wording, {time.monotonic() - t0:.1f} s")


if __name__ == "__main__":
    import sys

    from dotenv import load_dotenv

    load_dotenv()
    start = (42.449626, -76.481794)  # PSB
    if sys.argv[1:2] == ["--warm"]:
        if len(sys.argv) > 2:
            start = tuple(float(x) for x in sys.argv[2].split(","))
        names = sorted({p["name"] for p in KNOWN_PLACES.values()} - {"Physical Sciences Building"}) + ["Rockefeller Hall"]
        print(f"warming the cache from {start}")
        warm(start, names)
        sys.exit()
    place = find_place(" ".join(sys.argv[1:]) or "Malott Hall", near=start)
    if place is None:
        sys.exit("no place found")
    route = get_route(start, place)
    door = route["destination"]
    print(f"{place['name']}: {len(place.get('doors') or [])} doors, routed to ({door['lat']:.6f}, {door['lng']:.6f}), "
          f"{route['distance_m']:.0f} m, {len(route['polyline'])} points")
    import guidance
    for st in route["steps"]:
        print(f"  {st['along_m']:6.1f} m  rules:  {guidance.turn_phrase(st, polished=False)}")
        if st.get("say_ahead"):
            print(f"            gemini: In NN meters, {st['say_ahead']}.  |  {st['say_now']}")
    print(f"  arrival: {guidance.arrival_say({'pos': (door['lat'], door['lng']), 'course': None, 'speed': None, 'heading': None, 'route': route, 'seg_i': len(route['polyline']) - 2}, door)}")
