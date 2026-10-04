"""What the walking paths along a route are like, from OpenStreetMap: stairs, archways, street
crossings, and which of two paths at a fork is the smaller one."""
import math
import time

import httpx

import cache
import geo

OVERPASS_URL = "https://overpass-api.de/api/interpreter"
RETRY_WAITS_S = (0, 1, 3)
TILE_DEG = 0.005   # paths are fetched in fixed ~500 m tiles, so every trip reuses the cache
HEADERS = {"User-Agent": "AcousticMaps/0.1 (hackathon)"}
PAD_DEG = 0.0003   # about 30 m around the route
NEAR_M = 4         # a route point this close to a path is on it
SAMPLE_M = 2
SAME_GAP_M = 30
TOWARD_AHEAD_M = 50   # look this far down the new path for a building to name
TOWARD_MIN_LEG_M = 20
TOWARD_NEAR_M = 25
SAME_SIDE_MIN, SAME_SIDE_MAX = 20, 170
SIZE = {"steps": 1, "path": 1, "footway": 1, "pedestrian": 2, "cycleway": 2, "service": 3}  # anything else is a street


def overpass(query):
    """Run an Overpass query, cached on disk. The public server refuses bursts, so retry a couple of times."""
    hit = cache.get("overpass", query)
    if hit is not None:
        return hit
    for wait in RETRY_WAITS_S:
        time.sleep(wait)
        try:
            r = httpx.post(OVERPASS_URL, data={"data": query}, headers=HEADERS, timeout=15)
            r.raise_for_status()
            elements = r.json()["elements"]
        except (httpx.HTTPError, ValueError):
            continue
        cache.put("overpass", query, elements)
        return elements
    return None


def fetch_ways(polyline, selector="way[highway]"):
    """Every path near the route (or other ways, e.g. named buildings), or None if OpenStreetMap can't be reached."""
    lats, lngs = [p[0] for p in polyline], [p[1] for p in polyline]
    lo_lat, hi_lat = min(lats) - PAD_DEG, max(lats) + PAD_DEG
    lo_lng, hi_lng = min(lngs) - PAD_DEG, max(lngs) + PAD_DEG
    ways, seen = [], set()
    for i in range(math.floor(lo_lat / TILE_DEG), math.floor(hi_lat / TILE_DEG) + 1):
        for j in range(math.floor(lo_lng / TILE_DEG), math.floor(hi_lng / TILE_DEG) + 1):
            box = f"{i * TILE_DEG:.3f},{j * TILE_DEG:.3f},{(i + 1) * TILE_DEG:.3f},{(j + 1) * TILE_DEG:.3f}"
            elements = overpass(f"[out:json][timeout:25];{selector}({box});out tags geom;")
            if elements is None:
                return None
            for e in elements:
                geom = [(g["lat"], g["lon"]) for g in e.get("geometry", [])]
                if e["id"] in seen or len(geom) < 2:
                    continue
                if not any(lo_lat <= a <= hi_lat and lo_lng <= b <= hi_lng for a, b in geom):
                    continue
                seen.add(e["id"])
                ways.append({"tags": e["tags"], "geom": geom, "cum": geo.cumulative_m(geom)})
    return ways


def kind(tags):
    if tags.get("highway") == "steps":
        return "stairs"
    if tags.get("tunnel") == "building_passage":
        return "archway"
    if tags.get("footway") == "crossing" or tags.get("highway") == "crossing":
        return "crossing"
    return None


def nearest_way(ways, p, max_m=NEAR_M):
    best, best_off = None, max_m
    for w in ways:
        _, off, _ = geo.locate(p, w["geom"], w["cum"])
        if off <= best_off:
            best, best_off = w, off
    return best


def features(route, ways):
    """[(along_m, "stairs" | "archway" | "crossing")]: where the route starts along each one."""
    special = [w for w in ways if kind(w["tags"])]
    poly, cum, found, last_seen = route["polyline"], route["cum"], [], {}
    along = 0.0
    while along <= cum[-1]:
        w = nearest_way(special, geo.point_at(poly, cum, along), NEAR_M)
        k = kind(w["tags"]) if w else None
        # OSM splits one flight of stairs or one crossing into pieces: count them once
        if k and along - last_seen.get(k, -SAME_GAP_M - 1) > SAME_GAP_M:
            found.append((along, k))
        if k:
            last_seen[k] = along
        along += SAMPLE_M
    return found


def size_word(chosen, other):
    """'the smaller path' / 'the wider path' when the two branches differ, else None."""
    a, b = SIZE.get(chosen.get("highway"), 4), SIZE.get(other.get("highway"), 4)
    if a == b:
        return None
    if a == 1:
        return "the footpath" if b >= 3 else "the smaller path"
    if a >= 3 and b == 1:
        return "the road"
    return "the smaller path" if a < b else "the wider path"


def branch_note(ways, at, out_bearing, other_bearings, in_bearing):
    """Describe the branch taken at a fork, compared with the other near-straight branch."""
    others = [b for b in other_bearings if abs(geo.angle_diff(in_bearing, b)) <= 45]
    if not others:
        return None
    chosen = nearest_way(ways, geo.move(at, out_bearing, 8))
    other = nearest_way(ways, geo.move(at, others[0], 8))
    if chosen is None or other is None or chosen is other:
        return None
    return size_word(chosen["tags"], other["tags"])


def toward(route, step, buildings, end_along):
    """Name of a building the path after this step heads toward, or None."""
    leg_end = min(step["along_m"] + TOWARD_AHEAD_M, end_along)
    if leg_end - step["along_m"] < TOWARD_MIN_LEG_M:
        return None
    p = geo.point_at(route["polyline"], route["cum"], leg_end)
    here = (step["lat"], step["lng"])
    best, best_off = None, TOWARD_NEAR_M
    for b in buildings:
        _, off, _ = geo.locate(p, b["geom"], b["cum"])
        _, off_here, _ = geo.locate(here, b["geom"], b["cum"])
        if off <= best_off and off < off_here:  # ahead on the new path, not beside the corner
            best, best_off = b, off
    return best["tags"]["name"] if best else None


def which_one(in_bearing, out_bearing, other_bearings):
    """When two exits lie on the same side: 'slight' or 'sharp' for the one taken, else None."""
    out = geo.angle_diff(in_bearing, out_bearing)
    same = [geo.angle_diff(in_bearing, b) for b in other_bearings]
    same = [a for a in same if (a > 0) == (out > 0) and SAME_SIDE_MIN <= abs(a) <= SAME_SIDE_MAX]
    if not same:
        return None
    if all(abs(out) < abs(a) for a in same):
        return "slight"
    if all(abs(out) > abs(a) for a in same):
        return "sharp"
    return "middle"
