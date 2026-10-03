"""Route visualizer: draws a route (and optionally a recorded walk) on a map, as one HTML file.

    python viz.py mock/routes/l_turns.json                         # route only
    python viz.py mock/routes/l_turns.json logs/SESSION.jsonl      # route + walk
    python viz.py ROUTE.json [LOG.jsonl] -o viz/NAME.html

Standard library only (plus geo.py). The page loads Leaflet from unpkg and OpenStreetMap tiles.
It also checks the route (turn directions, step order) and prints any problems.
"""
import argparse
import copy
import json
import sys
from pathlib import Path

import geo

HERE = Path(__file__).parent
AHEAD_M, NOW_M, ARRIVE_M = 40, 10, 12  # same distances as guidance.py / navigation.md


# ---------- route ----------

def load_route(path):
    with open(path) as f:
        return json.load(f)


def prepare(route):
    """Same as routing.prepare: add cum and each step's along_m, locating steps in order."""
    route = copy.deepcopy(route)
    poly = [tuple(p) for p in route["polyline"]]
    cum = geo.cumulative_m(poly)
    route["cum"] = cum
    lo = 0.0
    for step in route["steps"]:
        along, off, seg_i = geo.locate((step["lat"], step["lng"]), poly, cum, lo)
        step["along_m"] = along
        step["snap_off_m"] = off
        lo = along
    return route


def check_route(route):
    """Return a list of problems (empty means the route looks right). Expects a prepared route."""
    problems = []
    poly = [tuple(p) for p in route["polyline"]]
    steps, cum = route["steps"], route["cum"]
    if not steps or steps[-1]["turn"] != "arrive":
        problems.append("last step must have turn 'arrive'")
    prev_along = -1.0
    for n, step in enumerate(steps, 1):
        point = (step["lat"], step["lng"])
        if step["along_m"] <= prev_along:
            problems.append(f"step {n}: along_m {step['along_m']:.1f} does not increase")
        prev_along = step["along_m"]
        if step["snap_off_m"] > 1:
            problems.append(f"step {n}: {step['snap_off_m']:.1f} m off the polyline")
        # find the vertex at this along_m (a route can pass the same point twice)
        vi = min(range(len(poly)), key=lambda i: abs(cum[i] - step["along_m"]))
        if geo.distance_m(poly[vi], point) > 0.5:
            problems.append(f"step {n}: not on a polyline vertex")
            continue
        if step["turn"] in ("left", "right"):
            if vi == 0 or vi == len(poly) - 1:
                problems.append(f"step {n}: a turn at the end of the polyline")
                continue
            d = geo.angle_diff(geo.bearing_deg(poly[vi - 1], poly[vi]),
                               geo.bearing_deg(poly[vi], poly[vi + 1]))
            actual = "right" if d > 0 else "left"
            if abs(d) < 30:
                problems.append(f"step {n}: '{step['turn']}' but the path bends only {d:.0f} deg")
            elif actual != step["turn"]:
                problems.append(f"step {n}: says '{step['turn']}' but geometry turns {actual} ({d:.0f} deg)")
        expected_leg = step["along_m"] - (steps[n - 2]["along_m"] if n > 1 else 0.0)
        if "distance_m" in step and abs(step["distance_m"] - expected_leg) > 2:
            problems.append(f"step {n}: distance_m {step['distance_m']} but leg is {expected_leg:.1f} m")
    if abs(route.get("distance_m", cum[-1]) - cum[-1]) > 2:
        problems.append(f"distance_m {route['distance_m']} but polyline is {cum[-1]:.1f} m")
    dest = route["destination"]
    if geo.distance_m((dest["lat"], dest["lng"]), poly[-1]) > ARRIVE_M:
        problems.append("destination is more than 12 m from the end of the polyline")
    return problems


# ---------- walk log ----------

def load_log(path):
    ticks = []
    with open(path) as f:
        for line in f:
            if line.strip():
                ticks.append(json.loads(line))
    return ticks


def walk_ticks(route, log):
    """One entry per logged /update, with where it was relative to the route."""
    poly = [tuple(p) for p in route["polyline"]]
    out = []
    for i, entry in enumerate(log):
        req, resp = entry.get("request", {}), entry.get("response", {})
        if req.get("lat") is None or req.get("lng") is None:
            continue
        along, off, _ = geo.locate((req["lat"], req["lng"]), poly, route["cum"])
        out.append({"i": i, "t": entry.get("t", ""), "lat": req["lat"], "lng": req["lng"],
                    "state": resp.get("state"), "say": resp.get("say"), "haptic": resp.get("haptic"),
                    "along_m": round(along, 1), "off_m": round(off, 1),
                    "request": req, "response": resp})
    return out


# ---------- html ----------

def page_data(route, ticks, problems, title):
    return {
        "title": title,
        "scenario": route.get("scenario"),
        "destination": route["destination"],
        "polyline": route["polyline"],
        "length_m": round(route["cum"][-1], 1),
        "steps": [{"n": n, "lat": s["lat"], "lng": s["lng"], "turn": s["turn"], "street": s["street"],
                   "distance_m": s.get("distance_m"), "along_m": round(s["along_m"], 1)}
                  for n, s in enumerate(route["steps"], 1)],
        "radii": {"ahead": AHEAD_M, "now": NOW_M, "arrive": ARRIVE_M},
        "problems": problems,
        "ticks": ticks,
    }


def render(data):
    blob = json.dumps(data).replace("</", "<\\/")  # keep "</script>" out of the inline JSON
    return TEMPLATE.replace("__TITLE__", data["title"]).replace("__DATA__", blob)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("route")
    ap.add_argument("log", nargs="?")
    ap.add_argument("-o", "--out")
    args = ap.parse_args()

    route = prepare(load_route(args.route))
    problems = check_route(route)
    ticks = walk_ticks(route, load_log(args.log)) if args.log else []

    name = Path(args.route).stem + (f"__{Path(args.log).stem[:8]}" if args.log else "")
    out = Path(args.out) if args.out else HERE / "viz" / f"{name}.html"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(render(page_data(route, ticks, problems, name)))

    for p in problems:
        print("PROBLEM:", p)
    events = sum(1 for t in ticks if t["say"] or t["haptic"])
    print(f"route {route['cum'][-1]:.0f} m, {len(route['steps'])} steps"
          + (f", {len(ticks)} ticks, {events} events" if args.log else ""))
    print(f"wrote {out.resolve()}")
    return 1 if problems else 0


TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<style>
  :root { --bg:#fff; --fg:#1d1d1f; --muted:#6e6e73; --line:#e3e3e8; --panel:#f7f7f9;
          --route:#7c3aed; --idle:#8e8e93; --nav:#2563eb; --off:#dc2626; --arr:#16a34a; --other:#d97706; }
  @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
          --bg:#141416; --fg:#f2f2f7; --muted:#a1a1a6; --line:#2c2c30; --panel:#1c1c1f; } }
  :root[data-theme="dark"] { --bg:#141416; --fg:#f2f2f7; --muted:#a1a1a6; --line:#2c2c30; --panel:#1c1c1f; }
  * { box-sizing: border-box; }
  html, body { margin:0; height:100%; background:var(--bg); color:var(--fg);
               font:14px/1.4 -apple-system, system-ui, sans-serif; }
  #app { display:flex; height:100%; }
  #side { width:380px; overflow:auto; border-right:1px solid var(--line); background:var(--panel); padding:12px 16px; }
  #map { flex:1; }
  h1 { font-size:18px; margin:0 0 4px; } h2 { font-size:13px; text-transform:uppercase; letter-spacing:.04em;
       color:var(--muted); margin:16px 0 6px; }
  .muted { color:var(--muted); } ul { padding-left:18px; margin:4px 0; }
  .bad { color:var(--off); } .ok { color:var(--arr); }
  .ev { padding:6px 8px; border:1px solid var(--line); border-radius:6px; margin:4px 0; cursor:pointer; background:var(--bg); }
  .ev:hover, .ev.sel { border-color:var(--nav); }
  .chip { display:inline-block; font-size:11px; padding:0 6px; border-radius:9px; color:#fff; margin-right:4px; }
  input[type=range] { width:100%; }
  pre { white-space:pre-wrap; word-break:break-all; font-size:11px; background:var(--bg);
        border:1px solid var(--line); border-radius:6px; padding:6px; margin:4px 0; }
  .legend span { margin-right:10px; white-space:nowrap; }
  .dot { display:inline-block; width:10px; height:10px; border-radius:50%; vertical-align:middle; margin-right:3px; }
  .turnicon { background:var(--route); color:#fff; border:2px solid #fff; border-radius:50%; width:22px; height:22px;
              text-align:center; line-height:18px; font-weight:600; font-size:12px; box-shadow:0 0 2px #0008; }
  @media (max-width: 760px) { #app { flex-direction:column; } #side { width:100%; height:45%; border-right:0;
       border-bottom:1px solid var(--line); } #map { height:55%; } }
</style>
</head>
<body>
<div id="app">
  <div id="side">
    <h1 id="title"></h1>
    <div id="summary" class="muted"></div>
    <div id="scenario"></div>
    <div id="problems"></div>
    <h2>Turns</h2>
    <ol id="steps"></ol>
    <div id="walk" hidden>
      <h2>Walk</h2>
      <div class="legend" id="legend"></div>
      <input type="range" id="slider" min="0" value="0">
      <div id="tickinfo"></div>
      <h2>Spoken / haptic events</h2>
      <div id="events"></div>
    </div>
  </div>
  <div id="map"></div>
</div>
<script>
const D = __DATA__;
const COLORS = { idle:"--idle", navigating:"--nav", off_route:"--off", arrived:"--arr" };
const css = v => getComputedStyle(document.documentElement).getPropertyValue(v).trim();
const stateColor = s => css(COLORS[s] || "--other");
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));

const map = L.map("map");
L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png",
  { maxZoom: 21, maxNativeZoom: 19, attribution: "&copy; OpenStreetMap contributors" }).addTo(map);

// ----- route -----
document.getElementById("title").textContent = D.title;
document.getElementById("summary").textContent =
  `${D.destination.name} · ${D.length_m} m · ${D.steps.length} steps` + (D.ticks.length ? ` · ${D.ticks.length} ticks` : "");
if (D.scenario) {
  document.getElementById("scenario").innerHTML = `<h2>Scenario</h2><div>${esc(D.scenario.tests)}</div>` +
    `<h2>Expect</h2><ul>${(D.scenario.expect || []).map(e => `<li>${esc(e)}</li>`).join("")}</ul>`;
}
document.getElementById("problems").innerHTML = D.problems.length
  ? `<h2>Route problems</h2><ul class="bad">${D.problems.map(p => `<li>${esc(p)}</li>`).join("")}</ul>`
  : `<h2>Route check</h2><div class="ok">Turn directions and step order OK</div>`;

const routeLine = L.polyline(D.polyline, { color: css("--route"), weight: 5, opacity: .8 }).addTo(map);
L.circleMarker(D.polyline[0], { radius: 6, color: "#fff", weight: 2, fillColor: css("--route"), fillOpacity: 1 })
  .addTo(map).bindTooltip("start");
const stepsEl = document.getElementById("steps");
D.steps.forEach(s => {
  const popup = `<b>${s.n}. ${esc(s.turn)}</b> ${esc(s.street)}<br>along ${s.along_m} m<br>leg ${s.distance_m} m`;
  if (s.turn === "arrive") {
    L.circle([s.lat, s.lng], { radius: D.radii.arrive, color: css("--arr"), weight: 2, fillOpacity: .12 })
      .addTo(map).bindPopup(`<b>arrival radius ${D.radii.arrive} m</b><br>` + popup);
  } else {
    for (const [r, dash] of [[D.radii.ahead, "6 6"], [D.radii.now, "3 4"]])
      L.circle([s.lat, s.lng], { radius: r, color: css("--route"), weight: 1.5, dashArray: dash, fill: false,
        interactive: false }).addTo(map);
  }
  const icon = L.divIcon({ className: "", html: `<div class="turnicon">${s.n}</div>`, iconSize: [22, 22], iconAnchor: [11, 11] });
  L.marker([s.lat, s.lng], { icon }).addTo(map).bindPopup(popup);
  const li = document.createElement("li");
  li.innerHTML = `<b>${esc(s.turn)}</b> ${esc(s.street)} <span class="muted">· along ${s.along_m} m</span>`;
  stepsEl.appendChild(li);
});
let bounds = routeLine.getBounds();

// ----- walk -----
if (D.ticks.length) {
  document.getElementById("walk").hidden = false;
  document.getElementById("legend").innerHTML = Object.entries(COLORS)
    .map(([k, v]) => `<span><i class="dot" style="background:${css(v)}"></i>${k}</span>`).join("");
  const T = D.ticks;
  for (let k = 1; k < T.length; k++)
    L.polyline([[T[k-1].lat, T[k-1].lng], [T[k].lat, T[k].lng]],
      { color: stateColor(T[k].state), weight: 3, opacity: .9 }).addTo(map);
  T.forEach((t, k) => L.circleMarker([t.lat, t.lng], { radius: 2.5, weight: 0, fillColor: stateColor(t.state),
    fillOpacity: 1 }).addTo(map).on("click", () => select(k)));

  const evEl = document.getElementById("events");
  const eventMarkers = {};
  let lastEv = null;
  T.forEach((t, k) => {
    if (!t.say && !t.haptic) return;
    const time = (t.t || "").slice(11, 19);
    const html = `<b>tick ${t.i}</b> ${esc(time)}<br>${t.say ? "say: " + esc(t.say) + "<br>" : ""}` +
      `${t.haptic ? "haptic: " + esc(t.haptic) + "<br>" : ""}state: ${esc(t.state)}<br>` +
      `along ${t.along_m} m · off route ${t.off_m} m`;
    eventMarkers[k] = L.circleMarker([t.lat, t.lng], { radius: 8, color: "#fff", weight: 2,
      fillColor: stateColor(t.state), fillOpacity: 1 }).addTo(map).bindPopup(html);
    eventMarkers[k].on("click", () => select(k, false));
    // the same say/haptic/state as the previous event tick: count it as a repeat instead of a new row
    const key = JSON.stringify([t.say, t.haptic, t.state]);
    if (lastEv && lastEv.key === key && lastEv.k === k - 1) {
      lastEv.n++; lastEv.k = k;
      lastEv.rep.innerHTML = ` <span class="bad">repeated ×${lastEv.n} (to tick ${t.i})</span>`;
      return;
    }
    const div = document.createElement("div");
    div.className = "ev"; div.dataset.k = k;
    div.innerHTML = `<span class="chip" style="background:${stateColor(t.state)}">${esc(t.state)}</span>` +
      `<span class="muted">tick ${t.i} · ${esc(time)} · ${t.along_m} m</span><span></span><br>` +
      `${esc(t.say || "")}${t.haptic ? ` <span class="muted">[${esc(t.haptic)}]</span>` : ""}`;
    div.onclick = () => { select(k); eventMarkers[k].openPopup(); };
    evEl.appendChild(div);
    lastEv = { key, k, n: 1, rep: div.children[2] };
  });
  if (!evEl.children.length) evEl.innerHTML = `<div class="muted">none</div>`;

  const you = L.circleMarker([T[0].lat, T[0].lng], { radius: 9, color: css("--fg"), weight: 3,
    fillColor: "#facc15", fillOpacity: 1 }).addTo(map).bindTooltip("you are here");
  const slider = document.getElementById("slider");
  slider.max = T.length - 1;
  slider.oninput = () => select(+slider.value, false);

  function select(k, pan = true) {
    const t = T[k];
    slider.value = k;
    you.setLatLng([t.lat, t.lng]);
    if (pan) map.panTo([t.lat, t.lng]);
    document.querySelectorAll(".ev").forEach(e => e.classList.toggle("sel", +e.dataset.k === k));
    document.getElementById("tickinfo").innerHTML =
      `<div><b>tick ${t.i}</b> / ${T[T.length-1].i} · ${esc((t.t || "").slice(11, 23))} · ` +
      `<span class="chip" style="background:${stateColor(t.state)}">${esc(t.state)}</span></div>` +
      `<div class="muted">along ${t.along_m} m · off route ${t.off_m} m</div>` +
      `<div class="muted">request</div><pre>${esc(JSON.stringify(t.request, null, 1))}</pre>` +
      `<div class="muted">response</div><pre>${esc(JSON.stringify(t.response, null, 1))}</pre>`;
  }
  select(0, false);
  bounds = bounds.extend(L.latLngBounds(T.map(t => [t.lat, t.lng])));
}
map.fitBounds(bounds, { padding: [30, 30] });
</script>
</body>
</html>
"""

if __name__ == "__main__":
    sys.exit(main())
