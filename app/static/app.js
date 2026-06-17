/* Anumaan offline navigation — frontend (MapLibre GL + Protomaps PMTiles) */
"use strict";

// MapLibre uses [lng, lat]; our backend uses [lat, lon]. Helpers keep it straight.
const LL = (latlon) => [latlon[1], latlon[0]];      // [lat,lon] -> [lng,lat]
const GLYPHS = "/static/vendor/glyphs/{fontstack}/{range}.pbf";

// pmtiles protocol so MapLibre can read pmtiles:// sources.
const pmProtocol = new pmtiles.Protocol();
maplibregl.addProtocol("pmtiles", pmProtocol.tile);

const S = {
  areas: [], area: null, home: null,
  mode: null, start: null, dest: null, route: null,
  navTimer: null, markers: {}, follow: false, userPanning: false,
};

// ---- map ----
const map = new maplibregl.Map({
  container: "map",
  style: { version: 8, glyphs: GLYPHS, sources: {},
           layers: [{ id: "bg", type: "background", paint: { "background-color": "#0f1419" } }] },
  center: [-98.35, 39.5], zoom: 3, attributionControl: false,
});
map.addControl(new maplibregl.NavigationControl({ showCompass: false }), "top-left");
map.addControl(new maplibregl.AttributionControl({
  customAttribution: "© OpenStreetMap · Protomaps (offline)" }));

function areaStyle(slug) {
  return {
    version: 8,
    glyphs: GLYPHS,
    sprite: `${location.origin}/static/vendor/sprites/light`,
    sources: {
      protomaps: {
        type: "vector",
        url: `pmtiles://${location.origin}/areas/${slug}/basemap.pmtiles`,
        attribution: "© OpenStreetMap · Protomaps",
      },
    },
    layers: protomaps_themes_base.default("protomaps", "light", "en"),
  };
}

function loadBasemap(area) {
  if (!area.has_basemap) {
    toast("This area has no basemap (extraction was skipped).", true);
    return;
  }
  map.setStyle(areaStyle(area.slug));
  fitArea(area);                          // camera move is independent of style load
  map.once("style.load", () => {
    if (S.route) drawRoute(S.route);      // route layers are wiped by setStyle
  });
}

function fitArea(area) {
  const b = area.bbox; // [north, south, east, west]
  map.fitBounds([[b[3], b[1]], [b[2], b[0]]], { padding: 30, duration: 0 });
}

// ---- api ----
async function api(path, method, body) {
  const opt = { method: method || "GET", headers: { "Content-Type": "application/json" } };
  if (body) opt.body = JSON.stringify(body);
  const r = await fetch(path, opt);
  if (!r.ok) {
    let msg = r.statusText;
    try { msg = (await r.json()).detail || msg; } catch (e) {}
    throw new Error(msg);
  }
  return r.status === 204 ? null : r.json();
}

function toast(msg, isErr) {
  const t = document.getElementById("toast");
  t.textContent = msg; t.classList.toggle("err", !!isErr); t.classList.remove("hidden");
  clearTimeout(toast._t); toast._t = setTimeout(() => t.classList.add("hidden"), 4500);
}

// ---- tabs ----
document.querySelectorAll("#tabs button").forEach((b) => {
  b.onclick = () => {
    document.querySelectorAll("#tabs button").forEach((x) => x.classList.remove("active"));
    document.querySelectorAll(".tab").forEach((x) => x.classList.remove("active"));
    b.classList.add("active");
    document.getElementById("tab-" + b.dataset.tab).classList.add("active");
  };
});

// ---- maps: download ----
const radius = document.getElementById("dl-radius");
radius.oninput = () => { document.getElementById("dl-radius-val").textContent = (radius.value / 1000).toFixed(1); };

document.getElementById("dl-go").onclick = async () => {
  const name = document.getElementById("dl-name").value.trim() || "Area";
  const place = document.getElementById("dl-place").value.trim();
  if (!place) return toast("Enter a place to download", true);
  const prog = document.getElementById("dl-progress");
  const bar = document.getElementById("dl-bar");
  const msg = document.getElementById("dl-msg");
  prog.classList.remove("hidden"); bar.style.width = "0%"; msg.textContent = "starting…";
  try {
    const { job_id } = await api("/api/download", "POST",
      { name, query: place, radius_m: Number(radius.value) });
    const poll = setInterval(async () => {
      const j = await api(`/api/download/${job_id}`);
      bar.style.width = Math.round((j.frac || 0) * 100) + "%";
      msg.textContent = j.message || "";
      if (j.done) {
        clearInterval(poll);
        if (j.error) { toast("Download failed: " + j.error, true); msg.textContent = j.error; }
        else { toast("Area downloaded"); await loadAreas(); selectArea(j.area.slug); }
        setTimeout(() => prog.classList.add("hidden"), 2000);
      }
    }, 700);
  } catch (e) { toast(e.message, true); }
};

// ---- maps: area list ----
async function loadAreas() {
  const { areas } = await api("/api/areas");
  S.areas = areas;
  const ul = document.getElementById("area-list");
  ul.innerHTML = "";
  if (!areas.length) { ul.innerHTML = '<li class="sub">No areas yet — download one above.</li>'; return; }
  areas.forEach((a) => {
    const li = document.createElement("li");
    li.className = S.area && S.area.slug === a.slug ? "sel" : "";
    const bm = a.has_basemap ? `${Math.round((a.basemap_bytes||0)/1024)} KB basemap` : "no basemap";
    li.innerHTML = `<span><b>${a.name}</b><br><span class="sub">${(a.radius_m/1000).toFixed(1)} km ·
      ${a.node_count} nodes · ${bm}</span></span><span class="del">✕</span>`;
    li.querySelector("span").onclick = () => selectArea(a.slug);
    li.querySelector(".del").onclick = async (ev) => {
      ev.stopPropagation();
      if (!confirm(`Delete area "${a.name}"?`)) return;
      await api(`/api/areas/${a.slug}`, "DELETE");
      if (S.area && S.area.slug === a.slug) S.area = null;
      await loadAreas();
    };
    ul.appendChild(li);
  });
}

function selectArea(slug) {
  const a = S.areas.find((x) => x.slug === slug);
  if (!a) return;
  S.area = a;
  loadBasemap(a);
  loadAreas();
  loadHome();
  toast(`Active area: ${a.name}`);
}

// ---- home ----
document.getElementById("home-pick").onclick = () => setMode("home", "home-pick");
document.getElementById("home-save").onclick = async () => {
  if (!S.area || !S.home) return;
  await api("/api/home", "POST", { slug: S.area.slug, lat: S.home[0], lon: S.home[1] });
  toast("Home saved");
};

async function loadHome() {
  const h = await api("/api/home");
  if (h && h.lat != null && (!S.area || h.slug === S.area.slug)) {
    S.home = [h.lat, h.lon];
    placeMarker("home", S.home, "#e3b341");
    document.getElementById("home-info").textContent =
      `Home: ${h.lat.toFixed(5)}, ${h.lon.toFixed(5)}`;
    document.getElementById("home-save").disabled = false;
  }
}

// ---- navigate ----
document.getElementById("nav-speed").oninput = (e) =>
  { document.getElementById("nav-speed-val").textContent = e.target.value; };
document.getElementById("nav-set-start").onclick = () => setMode("start", "nav-set-start");
document.getElementById("nav-set-dest").onclick = () => setMode("dest", "nav-set-dest");
document.getElementById("nav-use-home").onclick = () => {
  if (!S.home) return toast("No home set", true);
  S.start = S.home.slice(); placeMarker("start", S.start, "#3fb950"); refreshRouteButton();
};
document.getElementById("nav-route").onclick = computeRoute;
document.getElementById("nav-start").onclick = startNav;
document.getElementById("nav-stop").onclick = stopNav;
document.getElementById("nav-advance").onclick = async () => {
  try { await api("/api/nav/advance", "POST"); toast("Snapped to the next milestone"); }
  catch (e) { toast(e.message, true); }
};

function refreshRouteButton() {
  document.getElementById("nav-route").disabled = !(S.area && S.start && S.dest);
}

async function computeRoute() {
  try {
    const r = await api("/api/route", "POST",
      { slug: S.area.slug, start: S.start, dest: S.dest });
    S.route = r;
    drawRoute(r);
    document.getElementById("route-info").innerHTML =
      `Route: <b>${(r.total_distance_m/1000).toFixed(2)} km</b>, ~${Math.round(r.est_time_s/60)} min,
       ${r.milestones.length - 1} legs`;
    document.getElementById("nav-start").disabled = false;
    toast("Route computed");
  } catch (e) { toast(e.message, true); }
}

function setGeoJSON(id, data, layerSpec) {
  const src = map.getSource(id);
  if (src) { src.setData(data); return; }
  map.addSource(id, { type: "geojson", data });
  map.addLayer(Object.assign({ id, source: id }, layerSpec));
}

function milestoneData(items, total) {
  return { type: "FeatureCollection", features: items.map(({ n, i }) => ({
    type: "Feature",
    properties: { last: i === total, first: i === 0, label: n.name || "" },
    geometry: { type: "Point", coordinates: [n.lon, n.lat] } })) };
}

function ensureMilestoneLayers(data) {
  if (map.getSource("milestones")) { map.getSource("milestones").setData(data); return; }
  map.addSource("milestones", { type: "geojson", data });
  map.addLayer({ id: "milestones", source: "milestones", type: "circle", paint: {
    "circle-radius": ["case", ["any", ["get", "first"], ["get", "last"]], 7, 5],
    "circle-color": ["case", ["get", "last"], "#f85149",
      ["get", "first"], "#3fb950", "#2f81f7"],
    "circle-stroke-width": 2, "circle-stroke-color": "#0f1419" } });
  map.addLayer({ id: "milestone-labels", source: "milestones", type: "symbol",
    layout: { "text-field": ["get", "label"], "text-size": 11,
      "text-offset": [0, 1.2], "text-anchor": "top",
      "text-font": ["Noto Sans Medium"] },
    paint: { "text-color": "#1a2029", "text-halo-color": "#f5f3ee", "text-halo-width": 1.5 } });
}

function drawRoute(r) {
  const line = { type: "Feature", geometry: { type: "LineString",
    coordinates: r.coords.map(LL) } };
  setGeoJSON("route", line, { type: "line",
    paint: { "line-color": "#2f81f7", "line-width": 5, "line-opacity": 0.85 },
    layout: { "line-cap": "round", "line-join": "round" } });
  const total = r.nodes.length - 1;
  ensureMilestoneLayers(milestoneData(r.nodes.map((n, i) => ({ n, i })), total));
  const b = new maplibregl.LngLatBounds();
  r.coords.forEach((c) => b.extend(LL(c)));
  map.fitBounds(b, { padding: 60, duration: 400 });
}

// During navigation: show only the current target milestone + the next one.
function showUpcomingMilestones(idx) {
  if (!S.route) return;
  const nodes = S.route.nodes, total = nodes.length - 1;
  const items = [];
  for (let k = idx; k <= Math.min(idx + 1, total); k++)
    if (nodes[k]) items.push({ n: nodes[k], i: k });
  if (map.getSource("milestones")) map.getSource("milestones").setData(milestoneData(items, total));
}

async function startNav() {
  try {
    const speed = Number(document.getElementById("nav-speed").value);
    const simulate = document.getElementById("nav-sim").checked;
    const st = await api("/api/nav/start", "POST",
      { slug: S.area.slug, start: S.start, dest: S.dest, speed, simulate });
    document.getElementById("hud").classList.remove("hidden");
    document.getElementById("nav-stop").classList.remove("hidden");
    document.getElementById("nav-advance").classList.remove("hidden");
    document.getElementById("nav-start").disabled = true;
    document.getElementById("phone-hint").innerHTML = simulate
      ? `Simulating phone telemetry locally.<br><span id="tele-status"></span>`
      : `<b>Enable Accelerometer + Gyroscope + Magnetometer, stream here:</b>
         <br>Sensor Logger (HTTP push) → <span class="mono">${st.sensor_url}</span>
         <br>or a UDP app → <span class="mono">${st.phone_target}</span>
         <br><span id="tele-status">waiting for telemetry…</span>`;
    // Follow mode: zoom in on the vehicle and track it.
    S.follow = true;
    map.easeTo({ center: LL(S.start), zoom: 16.5, duration: 800 });
    if (S.navTimer) clearInterval(S.navTimer);
    S.navTimer = setInterval(pollNav, 400);
    toast("Navigation started");
  } catch (e) { toast(e.message, true); }
}

async function stopNav() {
  if (S.navTimer) { clearInterval(S.navTimer); S.navTimer = null; }
  try { await api("/api/nav/stop", "POST"); } catch (e) {}
  document.getElementById("nav-stop").classList.add("hidden");
  document.getElementById("nav-advance").classList.add("hidden");
  document.getElementById("turn-banner").classList.add("hidden");
  document.getElementById("nav-start").disabled = false;
  S.follow = false;
  if (S.route) drawRoute(S.route);   // restore the full route + all milestones
  toast("Navigation stopped");
}

async function pollNav() {
  let s;
  try { s = await api("/api/nav/state"); } catch (e) { return; }
  if (!s.active && !s.complete) return;
  if (s.position) placeVehicle(s.position);
  showUpcomingMilestones(s.current_index);
  if (S.follow && !S.userPanning && s.position)
    map.easeTo({ center: LL(s.position), duration: 450 });
  document.getElementById("hud-speed").textContent = s.estimated_speed + " m/s";
  document.getElementById("hud-prog").textContent =
    `${(s.traveled_m/1000).toFixed(2)}/${(s.total_m/1000).toFixed(2)} km`;
  document.getElementById("hud-node").textContent = `${s.current_index}/${s.milestone_count}`;
  document.getElementById("hud-var").textContent = s.accel_variance + " g";
  const stat = document.getElementById("hud-stat");
  stat.textContent = s.is_stationary ? "YES" : "no";
  stat.classList.toggle("on", s.is_stationary);
  document.getElementById("hud-pkts").textContent = s.packets;
  const headEl = document.getElementById("hud-head");
  if (s.calibrated && s.true_heading != null) headEl.textContent = `${Math.round(s.true_heading)}°✓`;
  else if (s.has_mag) headEl.textContent = `${Math.round(s.heading_deg)}°`;
  else headEl.textContent = "–";
  headEl.style.color = s.off_route ? "var(--danger)" : "";
  if (s.off_route && !S.lastOff) toast("⚠ Heading is off the route — wrong turn?", true);
  S.lastOff = s.off_route;
  document.getElementById("hud-sensors").textContent =
    `A${s.has_gyro ? "·G" : ""}${s.has_mag ? "·M" : ""}${s.calibrated ? "·cal" : ""}`;

  const adv = document.getElementById("nav-advance");
  if (s.next_milestone) adv.textContent = `✓ I’ve reached: ${s.next_milestone}`;

  // Turn guidance banner
  const tb = document.getElementById("turn-banner");
  const lbl = s.next_turn_label || "";
  const isTurn = !["straight", "start", "arrive", ""].includes(lbl);
  if (isTurn) {
    const arrow = (s.next_turn_angle || 0) > 0 ? "↱" : "↰";
    const deg = Math.round(Math.abs(s.next_turn_angle || 0));
    let html = `<span class="big">${arrow} ${lbl} ~${deg}°</span> at ${s.next_milestone}`;
    if (s.has_gyro) html += `<br>sensed ${Math.abs(s.heading_change_deg).toFixed(0)}°` +
      (s.has_mag ? " (fused)" : " (gyro only)") + " so far";
    else html += `<br><span class="muted">enable Gyroscope + Magnetometer in Sensor Logger to auto-confirm turns</span>`;
    // "did you turn?" when held at the node with no turn sensed yet
    const pending = s.is_stationary || (s.has_gyro && Math.abs(s.heading_change_deg) < 15);
    tb.className = pending ? "pending" : "";
    tb.innerHTML = html;
    tb.classList.remove("hidden");
  } else {
    tb.classList.add("hidden");
  }

  const tele = document.getElementById("tele-status");
  if (tele) {
    if (s.telemetry_connected) {
      tele.innerHTML = s.moving
        ? "📡 connected · <b>moving</b> — advancing"
        : "📡 connected · <b>stopped</b> — holding position";
      tele.className = "tele ok";
    } else {
      tele.innerHTML = "no telemetry — car paused. Connect your phone to drive.";
      tele.className = "tele warn";
    }
  }

  const log = document.getElementById("event-log");
  log.innerHTML = "";
  (s.events || []).slice().reverse().forEach((e) => {
    const li = document.createElement("li");
    li.className = e.snapped ? "snap" : "";
    li.textContent = (e.snapped ? "✅ " : "⏳ ") + e.message +
      (e.v_true != null ? ` (V=${e.v_true} m/s)` : "");
    log.appendChild(li);
  });

  if (s.complete) {
    clearInterval(S.navTimer); S.navTimer = null;
    document.getElementById("nav-stop").classList.add("hidden");
    document.getElementById("nav-advance").classList.add("hidden");
    document.getElementById("nav-start").disabled = false;
    S.follow = false;
    if (S.route) drawRoute(S.route);
    toast("🏁 Arrived at destination");
  }
}

// ---- markers + map click ----
function setMode(mode, btnId) {
  S.mode = mode;
  document.querySelectorAll("#sidebar button").forEach((b) => b.classList.remove("active-mode"));
  if (btnId) document.getElementById(btnId).classList.add("active-mode");
  toast(`Click the map to set ${mode}`);
}

function placeMarker(kind, latlon, color) {
  if (S.markers[kind]) S.markers[kind].remove();
  S.markers[kind] = new maplibregl.Marker({ color }).setLngLat(LL(latlon)).addTo(map);
}

function placeVehicle(latlon) {
  if (!S.markers.veh) {
    const el = document.createElement("div");
    el.className = "veh-marker"; el.textContent = "🚗";
    S.markers.veh = new maplibregl.Marker({ element: el }).setLngLat(LL(latlon)).addTo(map);
  } else {
    S.markers.veh.setLngLat(LL(latlon));
  }
}

map.on("click", (e) => {
  const ll = [e.lngLat.lat, e.lngLat.lng];
  if (S.mode === "home") {
    S.home = ll; placeMarker("home", ll, "#e3b341");
    document.getElementById("home-save").disabled = false;
    document.getElementById("home-info").textContent = `Home: ${ll[0].toFixed(5)}, ${ll[1].toFixed(5)}`;
  } else if (S.mode === "start") {
    S.start = ll; placeMarker("start", ll, "#3fb950"); refreshRouteButton();
  } else if (S.mode === "dest") {
    S.dest = ll; placeMarker("dest", ll, "#f85149"); refreshRouteButton();
  } else { return; }
  S.mode = null;
  document.querySelectorAll("#sidebar button").forEach((b) => b.classList.remove("active-mode"));
});

// Pause camera-follow briefly when the user drags the map, so we don't fight them.
map.on("dragstart", () => {
  S.userPanning = true;
  clearTimeout(S._panT);
  S._panT = setTimeout(() => { S.userPanning = false; }, 8000);
});

// ---- boot ----
map.on("load", loadAreas);
