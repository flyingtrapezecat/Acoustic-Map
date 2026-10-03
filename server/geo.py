"""Geometry on the Earth's surface. Points are (lat, lng) in degrees; distances are meters."""
import math

EARTH_R = 6_371_000  # meters


def distance_m(a, b):
    """Great-circle (haversine) distance between two points."""
    lat1, lng1, lat2, lng2 = map(math.radians, (*a, *b))
    h = (math.sin((lat2 - lat1) / 2) ** 2
         + math.cos(lat1) * math.cos(lat2) * math.sin((lng2 - lng1) / 2) ** 2)
    return 2 * EARTH_R * math.asin(math.sqrt(h))


def bearing_deg(a, b):
    """Compass bearing from a to b: 0 = north, 90 = east."""
    lat1, lng1, lat2, lng2 = map(math.radians, (*a, *b))
    dlng = lng2 - lng1
    x = math.sin(dlng) * math.cos(lat2)
    y = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dlng)
    return math.degrees(math.atan2(x, y)) % 360


def move(a, bearing, meters):
    """The point you reach walking `meters` from a in direction `bearing`."""
    lat1, lng1 = map(math.radians, a)
    brg = math.radians(bearing)
    d = meters / EARTH_R
    lat2 = math.asin(math.sin(lat1) * math.cos(d)
                     + math.cos(lat1) * math.sin(d) * math.cos(brg))
    lng2 = lng1 + math.atan2(math.sin(brg) * math.sin(d) * math.cos(lat1),
                             math.cos(d) - math.sin(lat1) * math.sin(lat2))
    return (math.degrees(lat2), math.degrees(lng2))


def angle_diff(a, b):
    """Signed turn from bearing a to bearing b, in -180..180. Positive = b is to the right."""
    return (b - a + 180) % 360 - 180


def clock_face(heading, bearing):
    """Where `bearing` is for someone facing `heading`, as 1..12 o'clock (12 = straight ahead)."""
    hour = round(((bearing - heading) % 360) / 30) % 12
    return 12 if hour == 0 else hour


def cumulative_m(polyline):
    """Distance along the polyline at each vertex: [0, d01, d01+d12, ...]."""
    cum = [0.0]
    for a, b in zip(polyline, polyline[1:]):
        cum.append(cum[-1] + distance_m(a, b))
    return cum


def locate(p, polyline, cum, lo=0.0, hi=math.inf, prefer=None):
    """Snap p onto the polyline, looking only at the stretch between lo and hi meters along it.
    Returns (along_m, off_m, seg_i): how far along the route the snapped point is,
    how far p is from it, and which segment it's on."""
    if len(polyline) < 2:
        return 0.0, distance_m(p, polyline[0]), 0

    def to_xy(q):  # flat meters with p at (0, 0); accurate at walking scale
        x = math.radians(q[1] - p[1]) * EARTH_R * math.cos(math.radians(p[0]))
        y = math.radians(q[0] - p[0]) * EARTH_R
        return x, y

    best, best_score = (0.0, math.inf, 0), math.inf
    for i in range(len(polyline) - 1):
        seg_len = cum[i + 1] - cum[i]
        if seg_len == 0 or cum[i + 1] < lo or cum[i] > hi:
            continue  # zero-length, or outside the window
        (x1, y1), (x2, y2) = to_xy(polyline[i]), to_xy(polyline[i + 1])
        dx, dy = x2 - x1, y2 - y1
        t = -(x1 * dx + y1 * dy) / (dx * dx + dy * dy)  # closest point on the infinite line
        t_lo = max(0.0, (lo - cum[i]) / seg_len)          # keep it on the segment
        t_hi = min(1.0, (hi - cum[i]) / seg_len)          # and inside the window
        t = max(t_lo, min(t_hi, t))
        off = math.hypot(x1 + t * dx, y1 + t * dy)
        along = cum[i] + t * seg_len
        score = off
        if prefer is not None:
            score += 0.2 * max(0.0, along - prefer - 5)  # 1 m of penalty per 5 m jumped ahead
        if score < best_score:
            best, best_score = (along, off, i), score
    return best
