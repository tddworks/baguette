// sim-location.js — simulated-location map picker for the focus page.
//
// Hangs `window.LocationPanel` on the global so sim-native.js can surface
// a floating glass card with a Leaflet map. Click the map to drop a pin
// and "Set location"; switch to Route mode to drop two or more waypoints
// and "Start route" a moving location; switch to Walk mode to drive the
// device around with a joystick (or W A S D).
//
// The panel is a dumb sender: "Set location" POSTs
// `{latitude,longitude}`, "Start route" POSTs `{waypoints:[…],speed}`,
// Walk mode POSTs `{latitude,longitude,bearing,speed}`, and "Clear"
// sends DELETE — all to `/devices/<udid>/location`. The Swift side
// owns all domain logic (`simctl location` argv, range validation, the
// walk→route projection). Map tiles come from OpenStreetMap at runtime;
// only the Leaflet library itself is vendored. See
// `docs/features/location/README.md`.
//
// ## Why Walk mode sends a vector, not positions
//
// The obvious joystick — POST a new point every animation frame — can't
// work. Each `simctl location set` spawn costs ~277 ms (so ~3.6 Hz,
// visibly jerky), and a `set` pins a *stationary* point that locationd
// reports with `course = -1`, so no app could read a direction of
// travel. Instead the stick sends its **vector** only when the vector
// *changes*; Swift projects that into a two-waypoint route and the
// simulator's own daemon interpolates the motion smoothly, deriving
// `CLLocation.course` and `speed` from the travel. Releasing the stick
// POSTs a plain point, whose `course = -1` is exactly "stopped".
//
// This file therefore dead-reckons the pin locally (mirroring
// `Coordinate.projected` in Swift, same formula and earth radius) so the
// map animates at 60 fps while the wire stays near-silent.
//
// Three map conveniences are browser-side only:
//   • Search — geocodes a place name via OSM Nominatim and recentres the
//     map (no API key; a runtime fetch, like the tiles).
//   • Locate me — centres on the *host Mac's* real position via the
//     browser geolocation API. (simctl has no read-back, so the device's
//     own simulated position can't be queried — this is the Mac's GPS.)
//   • The Walk pin's dead reckoning — the device is the authority, but
//     it can't be polled, so the pin shows where we believe it is.

(function () {
  'use strict';

  // Apple Park — a friendly default centre when the device has no pin yet.
  const DEFAULT_CENTER = [37.3349, -122.0090];
  const DEFAULT_ZOOM = 13;
  const TILE_URL = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  const TILE_ATTR = '&copy; OpenStreetMap contributors';
  // OSM geocoder — free, no API key, CORS-enabled. Low-volume dev use
  // only; respect Nominatim's usage policy (1 req/sec).
  const GEOCODE_URL = 'https://nominatim.openstreetmap.org/search';
  const FOUND_ZOOM = 14;
  const WALK_ZOOM = 17;

  // ---- walk tuning ------------------------------------------------

  // Mean earth radius (IUGG), matching `Coordinate.earthRadius` in Swift
  // so the pin's dead reckoning traces the same line the device walks.
  const EARTH_RADIUS = 6371008.8;
  // Stick travel below this fraction of the pad radius reads as centred.
  // Analog sticks and trackpads both jitter; without a deadzone the
  // device would creep whenever the panel was merely open.
  const DEADZONE = 0.12;
  // Don't re-send a vector for changes the device can't meaningfully
  // show — each send is a ~430 ms spawn, so a swirling stick would
  // otherwise queue spawns faster than they drain.
  const BEARING_EPSILON = 2;      // degrees
  const SPEED_EPSILON = 0.1;      // m/s
  const SEND_INTERVAL_MS = 250;   // floor between sends (~4/s worst case)
  // Re-send an unchanged vector this often. The route Swift projects runs
  // for `LocationWalk.defaultHorizon` (600 s) before it runs out of road,
  // and re-sending also re-syncs the device to the pin.
  const KEEPALIVE_MS = 30_000;
  const BOOST = 3;                // shift multiplier on the keyboard
  // Degrees per second A/D sweep the heading. Deliberately unhurried:
  // each vector change costs a ~430 ms spawn, so a faster sweep would
  // just step the device's course in bigger jumps, not turn it sooner.
  const TURN_RATE = 90;
  // Trail sampling. Recording every animation frame (60/s) would bloat
  // the polyline and blow the request body on replay; a point every few
  // metres traces the same path for a fraction of the points.
  const TRAIL_MIN_METRES = 4;
  const TRAIL_MAX_POINTS = 500;

  const SPEED_PRESETS = [
    { label: 'Walk', speed: 1.4 },
    { label: 'Run', speed: 3.5 },
    { label: 'Cycle', speed: 6 },
    { label: 'Drive', speed: 13.4 },
    { label: 'Highway', speed: 29 },
  ];

  // Keys are *roles*, not compass directions: W/S drive along whatever
  // heading the device already has, A/D sweep that heading. This is what
  // makes the keyboard feel like a game rather than a compass rose — you
  // steer one persistent heading instead of picking absolute bearings.
  // (The joystick stays absolute; it sets the heading outright.)
  const KEY_ROLES = {
    KeyW: ['throttle', 1], ArrowUp: ['throttle', 1],
    KeyS: ['throttle', -1], ArrowDown: ['throttle', -1],
    KeyA: ['turn', -1], ArrowLeft: ['turn', -1],
    KeyD: ['turn', 1], ArrowRight: ['turn', 1],
  };

  function round6(n) { return Math.round(n * 1e6) / 1e6; }

  // Screen-space vector → compass degrees clockwise from north. `atan2`
  // of (x, -y) puts 0° at "up" and grows clockwise, which is exactly the
  // compass convention — no extra rotation needed.
  function bearingOf(dx, dy) {
    const deg = Math.atan2(dx, -dy) * 180 / Math.PI;
    return (deg + 360) % 360;
  }

  function cardinalOf(deg) {
    const points = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    return points[Math.round(deg / 45) % points.length];
  }

  // Metres between two points (haversine). Used to sample the trail
  // evenly and to walk it back during replay.
  function distanceBetween(a, b) {
    const p1 = a.lat * Math.PI / 180, p2 = b.lat * Math.PI / 180;
    const dp = (b.lat - a.lat) * Math.PI / 180, dl = (b.lon - a.lon) * Math.PI / 180;
    const h = Math.sin(dp / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) ** 2;
    return 2 * EARTH_RADIUS * Math.asin(Math.min(1, Math.sqrt(h)));
  }

  // Initial great-circle bearing from a to b — the inverse of `project`,
  // for retracing a recorded trail segment by segment.
  function bearingBetween(a, b) {
    const p1 = a.lat * Math.PI / 180, p2 = b.lat * Math.PI / 180;
    const dl = (b.lon - a.lon) * Math.PI / 180;
    const y = Math.sin(dl) * Math.cos(p2);
    const x = Math.cos(p1) * Math.sin(p2) - Math.sin(p1) * Math.cos(p2) * Math.cos(dl);
    return (Math.atan2(y, x) * 180 / Math.PI + 360) % 360;
  }

  // The great-circle destination formula — the JS twin of
  // `Coordinate.projected(bearing:metres:)`. Kept byte-for-byte
  // equivalent in behaviour so the locally reckoned pin and the device's
  // interpolated track can't disagree.
  function project(lat, lon, bearingDeg, metres) {
    if (!isFinite(metres) || metres === 0) return { lat, lon };
    const d = metres / EARTH_RADIUS;
    const p1 = lat * Math.PI / 180;
    const l1 = lon * Math.PI / 180;
    const t = bearingDeg * Math.PI / 180;
    const p2 = Math.asin(
      Math.sin(p1) * Math.cos(d) + Math.cos(p1) * Math.sin(d) * Math.cos(t)
    );
    const l2 = l1 + Math.atan2(
      Math.sin(t) * Math.sin(d) * Math.cos(p1),
      Math.cos(d) - Math.sin(p1) * Math.sin(p2)
    );
    let lon2 = l2 * 180 / Math.PI;
    if (lon2 > 180 || lon2 < -180) lon2 = ((lon2 + 540) % 360) - 180;
    return { lat: p2 * 180 / Math.PI, lon: lon2 };
  }

  class LocationPanel {
    constructor() {
      this.host = null;
      this.udid = null;
      this.map = null;
      this.mode = 'point';        // 'point' | 'route' | 'walk'
      this.marker = null;         // point/walk-mode draggable pin
      this.routePins = [];        // route-mode waypoint markers
      this.routeLine = null;      // route-mode polyline

      // ---- walk state ----
      // What we last told the device, and when. The pin's live position
      // is dead-reckoned forward from this pair, so it must only ever be
      // re-stamped together.
      this.walkOrigin = null;     // {lat, lon} handed to the last send
      this.walkOriginAt = 0;      // performance.now() of that send
      this.walkVector = null;     // {bearing, speed} in flight, or null when stopped
      this.walkSentVector = null; // the vector the device actually has

      // Heading is *persistent state*, not a property of the current
      // vector. It survives stopping — the device still points somewhere
      // once it's standing still, A/D can sweep it on the spot, and the
      // compass has something to show. (Deriving it from `walkVector`
      // meant the needle swung back to north the moment you let go.)
      this.heading = 0;           // degrees clockwise from north
      this.throttle = 0;          // -1 reverse · 0 stopped · +1 forward (keys)
      this.turn = 0;              // -1 left · 0 · +1 right (keys)
      this.lastFrameAt = 0;       // for integrating the turn over real time

      this.walkTrail = null;      // polyline of where we've walked
      this.trail = [];            // the same path as data, for replay
      this.replay = null;         // active replay animation, or null
      this.frame = null;          // rAF handle for the pin animation
      this.stickPointer = null;   // pointerId currently dragging the stick
      this.stickSpeed = 0;        // m/s the stick is currently asking for
      this.boost = false;
      this.sendInFlight = false;
      this.sendPending = false;   // a vector changed while a send was in flight
      this.lastSentAt = 0;
      this.tail = null;           // promise chain that orders every POST
      this.onKeyDown = null;      // bound listeners, so walk mode can unbind them
      this.onKeyUp = null;
      this.onBlur = null;
    }

    attach(host, udid) {
      if (!host || !udid) return;
      this.host = host;
      this.udid = udid;
      this._build();
      // Leaflet needs a sized, on-screen container; the card fades in via
      // opacity so it's laid out, but invalidate once on the next frame
      // to be safe against any mount-time zero-size race.
      requestAnimationFrame(() => { if (this.map) this.map.invalidateSize(); });
    }

    // Re-measure when the card is reopened (sim-native reuses the mounted
    // panel), so the tiles fill the container after any layout change.
    refresh() {
      if (this.map) requestAnimationFrame(() => this.map.invalidateSize());
    }

    detach() {
      // Before anything else: a walk leaves listeners on `window` and a
      // rAF loop running. Dropping the DOM without unbinding them would
      // leave the device walking with no way to stop it.
      this._teardownWalk();
      // The motion readout polls on a timer; a closed panel that kept it
      // running would GET every two seconds forever.
      this._stopMotionPoll();
      if (this.map) { this.map.remove(); this.map = null; }
      this.marker = null;
      this.routePins = [];
      this.routeLine = null;
      this.walkTrail = null;
      if (this.host) { this.host.innerHTML = ''; this.host = null; }
    }

    // ---- view construction --------------------------------------

    _build() {
      this.host.innerHTML =
        '<div class="loc-search">' +
          '<input class="loc-search-input" id="nativeLocationSearch" type="text" ' +
                 'placeholder="Search a place…" aria-label="Search a location">' +
          '<button class="loc-icon-btn" id="nativeLocationSearchBtn" title="Search" aria-label="Search">' +
            '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" ' +
                 'stroke-linecap="round" width="15" height="15" aria-hidden="true">' +
              '<circle cx="10.5" cy="10.5" r="6"/><path d="M15 15l4.5 4.5"/></svg>' +
          '</button>' +
          '<button class="loc-icon-btn" id="nativeLocationLocate" title="My current location" ' +
                  'aria-label="My current location">' +
            '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" ' +
                 'stroke-linecap="round" width="15" height="15" aria-hidden="true">' +
              '<circle cx="12" cy="12" r="4"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3"/></svg>' +
          '</button>' +
        '</div>' +
        '<div class="loc-modes">' +
          '<button class="loc-seg-btn active" data-mode="point">Point</button>' +
          '<button class="loc-seg-btn" data-mode="route">Route</button>' +
          '<button class="loc-seg-btn" data-mode="walk">Walk</button>' +
        '</div>' +
        '<div class="loc-map" id="nativeLocationMap"></div>' +
        '<div class="loc-readout" id="nativeLocationReadout">Click the map to choose a position.</div>' +
        // Motion rides on whatever the card is already doing: once armed,
        // the walk vector / route speed this panel posts classifies the
        // activity server-side. No second control surface, no new wire.
        // Hidden in Point mode — a pinned device isn't going anywhere — but
        // it reappears whenever motion is armed, so an armed toggle is never
        // invisible. Starts hidden because Point is the opening mode.
        '<div class="loc-row loc-motion" hidden>' +
          '<label class="loc-motion-toggle">' +
            '<input type="checkbox" id="nativeLocationMotion"> ' +
            '<span>Drive motion sensors</span>' +
          '</label>' +
          '<span class="loc-motion-state" id="nativeLocationMotionState"></span>' +
        '</div>' +
        '<div class="loc-row loc-route-only" hidden>' +
          '<label class="loc-row-label">Speed</label>' +
          '<input class="loc-field" id="nativeLocationSpeed" type="number" min="1" ' +
                 'placeholder="20" aria-label="Route speed in metres per second">' +
          '<span class="loc-unit">m/s</span>' +
        '</div>' +
        '<div class="loc-walk loc-walk-only" hidden>' +
          '<div class="loc-stick" id="nativeLocationStick" tabindex="0" role="slider" ' +
               'aria-label="Walk joystick — drag, or hold W A S D" ' +
               'aria-valuemin="0" aria-valuemax="360" aria-valuenow="0" aria-valuetext="stopped">' +
            '<span class="loc-stick-axis loc-stick-axis-v"></span>' +
            '<span class="loc-stick-axis loc-stick-axis-h"></span>' +
            '<span class="loc-stick-thumb" id="nativeLocationThumb"></span>' +
          '</div>' +
          '<div class="loc-walk-side">' +
            '<div class="loc-compass">' +
              '<span class="loc-compass-n">N</span>' +
              '<span class="loc-compass-needle" id="nativeLocationNeedle"></span>' +
            '</div>' +
            '<div class="loc-course" id="nativeLocationCourse">—</div>' +
            '<select class="loc-field loc-select" id="nativeLocationPreset" ' +
                    'aria-label="Walking speed">' +
              SPEED_PRESETS.map((p, i) =>
                `<option value="${p.speed}"${i === 0 ? ' selected' : ''}>` +
                `${p.label} · ${p.speed} m/s</option>`).join('') +
            '</select>' +
          '</div>' +
        '</div>' +
        '<div class="loc-hint loc-walk-only" hidden>' +
          '<kbd>W</kbd><kbd>S</kbd> drive along the heading · ' +
          '<kbd>A</kbd><kbd>D</kbd> turn · <kbd>Shift</kbd> boost · stick steers absolute' +
        '</div>' +
        '<div class="loc-actions">' +
          '<button class="loc-apply" id="nativeLocationApply" disabled>Set location</button>' +
          '<button class="loc-clear loc-walk-only" id="nativeLocationReplay" hidden disabled>Replay</button>' +
          '<button class="loc-clear" id="nativeLocationClear">Clear</button>' +
        '</div>';

      this.host.querySelectorAll('.loc-seg-btn').forEach((btn) => {
        btn.addEventListener('click', () => this._setMode(btn.getAttribute('data-mode')));
      });
      this.host.querySelector('#nativeLocationApply')
        .addEventListener('click', () => this._apply());
      this.host.querySelector('#nativeLocationClear')
        .addEventListener('click', () => this._clear());
      this.host.querySelector('#nativeLocationReplay')
        .addEventListener('click', () => {
          if (this.replay) this._endReplay('Replay stopped.');
          else this._replay();
        });

      this._setupMotion();

      this.host.querySelector('#nativeLocationSearchBtn')
        .addEventListener('click', () => this._search());
      this.host.querySelector('#nativeLocationSearch')
        .addEventListener('keydown', (e) => {
          if (e.key === 'Enter') { e.preventDefault(); this._search(); }
        });
      this.host.querySelector('#nativeLocationLocate')
        .addEventListener('click', () => this._locateMe());

      this._initMap();
    }

    _initMap() {
      if (typeof L === 'undefined') {
        this._readout('Map library failed to load — check your connection.');
        return;
      }
      const el = this.host.querySelector('#nativeLocationMap');
      this.map = L.map(el, { zoomControl: true, attributionControl: true })
        .setView(DEFAULT_CENTER, DEFAULT_ZOOM);
      L.tileLayer(TILE_URL, { maxZoom: 19, attribution: TILE_ATTR }).addTo(this.map);
      this.map.on('click', (e) => this._onMapClick(e.latlng));
    }

    _pinIcon() {
      return L.divIcon({
        className: 'loc-pin',
        html: '<span class="loc-pin-dot"></span>',
        iconSize: [16, 16],
        iconAnchor: [8, 8],
      });
    }

    // ---- mode + interaction -------------------------------------

    _setMode(mode) {
      if (mode === this.mode) return;
      if (this.mode === 'walk') this._teardownWalk();
      this.mode = mode;
      this.host.querySelectorAll('.loc-seg-btn').forEach((b) =>
        b.classList.toggle('active', b.getAttribute('data-mode') === mode));
      this.host.querySelectorAll('.loc-route-only').forEach((el) => {
        el.hidden = (mode !== 'route');
      });
      this.host.querySelectorAll('.loc-walk-only').forEach((el) => {
        el.hidden = (mode !== 'walk');
      });
      this._syncMotionVisibility();
      this.host.querySelector('#nativeLocationApply').textContent =
        (mode === 'route') ? 'Start route' : 'Set location';
      this._reset();
      if (mode === 'walk') this._setupWalk();
    }

    _reset() {
      if (this.marker) { this.map.removeLayer(this.marker); this.marker = null; }
      this.routePins.forEach((m) => this.map.removeLayer(m));
      this.routePins = [];
      if (this.routeLine) { this.map.removeLayer(this.routeLine); this.routeLine = null; }
      if (this.walkTrail) { this.map.removeLayer(this.walkTrail); this.walkTrail = null; }
      this.trail = [];
      this.replay = null;
      const hints = {
        route: 'Click the map to add waypoints (two or more).',
        walk: 'Click the map to drop the device, then drive it with the stick.',
      };
      this._readout(hints[this.mode] || 'Click the map to choose a position.');
      this._syncApply();
      this._syncReplay();
    }

    _onMapClick(latlng) {
      if (this.mode === 'route') {
        const m = L.marker(latlng, { icon: this._pinIcon() }).addTo(this.map);
        this.routePins.push(m);
        this._drawRoute();
        this._syncApply();
      } else {
        this._setPoint(latlng);
      }
    }

    // Drop or move the single point-mode pin — which doubles as the
    // device in Walk mode. Shared by map clicks, search results, and
    // "locate me".
    _setPoint(latlng) {
      if (!this.marker) {
        this.marker = L.marker(latlng, { icon: this._pinIcon(), draggable: true }).addTo(this.map);
        this.marker.on('move', (e) => this._readPoint(e.latlng));
        this.marker.on('moveend', () => { this._syncApply(); this._reorigin(); });
      } else {
        this.marker.setLatLng(latlng);
      }
      this._readPoint(latlng);
      this._syncApply();
      this._reorigin();
    }

    // Re-stamp the walk's dead-reckoning origin at the pin. Whenever the
    // pin is moved by hand — a map click, a drag, a search — the previous
    // origin/elapsed pair describes a journey that no longer happened.
    _reorigin() {
      if (this.mode !== 'walk' || !this.marker) return;
      const p = this.marker.getLatLng();
      this.walkOrigin = { lat: p.lat, lon: p.lng };
      this.walkOriginAt = performance.now();
      if (this.walkVector) this._send();
    }

    // Recentre on a coordinate. In Point mode it also drops the pin so
    // the result is immediately ready to send; in Route mode it just
    // pans there so the user can click to add waypoints.
    _goTo(lat, lon, label) {
      if (!this.map || isNaN(lat) || isNaN(lon)) return;
      this.map.setView([lat, lon], FOUND_ZOOM);
      if (this.mode === 'point') {
        this._setPoint(L.latLng(lat, lon));
      } else if (label) {
        this._readout(label + ' — click to add as a waypoint.');
      }
    }

    // ---- search + locate ----------------------------------------

    _search() {
      const input = this.host.querySelector('#nativeLocationSearch');
      const q = input && input.value.trim();
      if (!q) return;
      this._readout('Searching…');
      fetch(`${GEOCODE_URL}?format=json&limit=1&q=${encodeURIComponent(q)}`, {
        headers: { Accept: 'application/json' },
      })
        .then((r) => (r.ok ? r.json() : []))
        .then((results) => {
          if (!results || !results.length) { this._readout(`No match for “${q}”.`); return; }
          const r = results[0];
          this._goTo(parseFloat(r.lat), parseFloat(r.lon), r.display_name);
        })
        .catch(() => this._readout('Search failed — network error.'));
    }

    _locateMe() {
      if (!navigator.geolocation) { this._readout('This browser has no geolocation.'); return; }
      this._readout('Locating…');
      navigator.geolocation.getCurrentPosition(
        (pos) => this._goTo(pos.coords.latitude, pos.coords.longitude, 'Your location'),
        () => this._readout('Location permission denied or unavailable.'),
        { enableHighAccuracy: true, timeout: 8000 }
      );
    }

    // ---- motion --------------------------------------------------

    // Arming rewrites a simulator-wide DYLD_INSERT_LIBRARIES that dyld only
    // honours at exec time, so the toggle says out loud that the app has to
    // be relaunched. Everything after that is automatic: the walk vectors
    // and route speeds this card already posts classify the activity.
    _setupMotion() {
      const box = this.host.querySelector('#nativeLocationMotion');
      if (!box) return;
      box.addEventListener('change', () => this._toggleMotion(box.checked));
      this._syncMotionVisibility();
      this._refreshMotion();
    }

    // Point mode pins the device, so there is no movement for motion to
    // follow and the toggle has nothing to do — it belongs to Walk and
    // Route. The exception is an armed session: hiding a control that is
    // still on is exactly how someone forgets it is on, and this one keeps
    // injecting into every app they launch.
    _syncMotionVisibility() {
      const row = this.host.querySelector('.loc-motion');
      if (!row) return;
      const box = this.host.querySelector('#nativeLocationMotion');
      row.hidden = this.mode === 'point' && !(box && box.checked);
    }

    // Every arm and disarm goes through one chain, because the two are not
    // interchangeable in flight: flipping the toggle on then straight off
    // could otherwise land the POST *after* the DELETE and leave motion armed
    // while the UI said it had stopped — the exact state that gets forgotten
    // about and injects into every app launched afterwards.
    _toggleMotion(on) {
      this.motionChain = (this.motionChain || Promise.resolve())
        .then(() => this._applyMotionToggle(on))
        .catch(() => {});
      return this.motionChain;
    }

    _applyMotionToggle(on) {
      const url = `/devices/${encodeURIComponent(this.udid)}/motion`;
      if (!on) {
        this._stopMotionPoll();
        // A failed DELETE must not read as stopped: the dylib is still armed,
        // so put the toggle back rather than hiding it.
        return fetch(url, { method: 'DELETE' })
          .then((res) => {
            if (!res.ok) return Promise.reject(res);
            this._motionState('');
            this._syncMotionVisibility();
          })
          .catch(() => {
            this._motionState('still armed');
            this._readout('Motion stop failed — it is still injecting.');
            const box = this.host && this.host.querySelector('#nativeLocationMotion');
            if (box) box.checked = true;
            this._syncMotionVisibility();
          });
      }
      // Send the speed the card is set to move at and let the server
      // classify it — the same division of labour as every other control
      // here. Duplicating the activity thresholds in JS would put domain
      // logic in the frontend, and the two copies would drift.
      return fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ speed: this._presetSpeed() }),
      })
        .then((res) => (res.ok ? res.json() : res.json().then((e) => Promise.reject(e))))
        .then((state) => {
          this._paintMotion(state);
          this._motionHint();
          this._syncMotionVisibility();
          this._startMotionPoll();
        })
        .catch((err) => {
          // Report what the server said rather than guessing at one cause —
          // a 400 (bad body) and a 500 (no dylib in this build) need
          // different fixes.
          this._motionState('failed');
          this._readout(`Motion failed — ${(err && err.error) || 'network error'}`);
          this.host.querySelector('#nativeLocationMotion').checked = false;
        });
    }

    _startMotionPoll() {
      this._stopMotionPoll();
      // Slow on purpose: this is a readout, and the interesting number
      // (steps) only moves a couple of times a second.
      this.motionTimer = setInterval(() => this._refreshMotion(), 2000);
    }

    _stopMotionPoll() {
      if (this.motionTimer) clearInterval(this.motionTimer);
      this.motionTimer = null;
    }

    _refreshMotion() {
      fetch(`/devices/${encodeURIComponent(this.udid)}/motion`)
        .then((res) => (res.ok ? res.json() : Promise.reject(res)))
        .then((state) => {
          const box = this.host.querySelector('#nativeLocationMotion');
          if (box) box.checked = !!state.active;
          this._paintMotion(state);
          // An armed session keeps the row on screen even in Point mode.
          this._syncMotionVisibility();
          // Only an armed session is worth polling for; anything else leaves
          // a timer running with nothing to report.
          if (state.active) this._startMotionPoll();
          else this._stopMotionPoll();
        })
        .catch(() => {});
    }

    _paintMotion(state) {
      if (!state || !state.active) { this._motionState(''); return; }
      // Show the speed behind the classification, so a surprising activity
      // ("why does it say cycling?") explains itself.
      const speed = state.speed > 0 ? ` · ${state.speed} m/s` : '';
      const steps = state.steps ? ` · ${state.steps} steps` : '';
      this._motionState(`${state.activity}${speed}${steps}`);
    }

    _motionState(text) {
      const el = this.host.querySelector('#nativeLocationMotionState');
      if (el) el.textContent = text;
    }

    _motionHint() {
      this._readout('Motion armed — relaunch the app to pick it up.');
    }

    // ---- walk mode ----------------------------------------------

    _setupWalk() {
      const stick = this.host.querySelector('#nativeLocationStick');
      stick.addEventListener('pointerdown', (e) => this._stickDown(e));
      stick.addEventListener('pointermove', (e) => this._stickMove(e));
      stick.addEventListener('pointerup', (e) => this._stickUp(e));
      stick.addEventListener('pointercancel', (e) => this._stickUp(e));
      this.host.querySelector('#nativeLocationPreset')
        .addEventListener('change', () => this._vectorChanged());

      // Keyboard is bound only while Walk mode is on screen, and unbound
      // the moment it isn't. The simulator's own key path doesn't capture
      // the browser today, but it's on the roadmap — a panel that
      // swallowed W/A/S/D globally would be a nasty surprise later.
      this.onKeyDown = (e) => this._keyDown(e);
      this.onKeyUp = (e) => this._keyUp(e);
      // A window blur (cmd-tab away mid-stride) never delivers keyup, so
      // the device would walk off forever. Treat losing focus as release.
      this.onBlur = () => this._releaseAll();
      window.addEventListener('keydown', this.onKeyDown);
      window.addEventListener('keyup', this.onKeyUp);
      window.addEventListener('blur', this.onBlur);
      this._paintCompass();
      this._syncReplay();
    }

    _teardownWalk() {
      this.replay = null;
      this._releaseAll();
      if (this.onKeyDown) window.removeEventListener('keydown', this.onKeyDown);
      if (this.onKeyUp) window.removeEventListener('keyup', this.onKeyUp);
      if (this.onBlur) window.removeEventListener('blur', this.onBlur);
      this.onKeyDown = this.onKeyUp = this.onBlur = null;
      if (this.frame) { cancelAnimationFrame(this.frame); this.frame = null; }
      this.lastFrameAt = 0;
      this.walkOrigin = null;
      this.walkVector = null;
      this.walkSentVector = null;
    }

    _presetSpeed() {
      const el = this.host.querySelector('#nativeLocationPreset');
      const v = el && parseFloat(el.value);
      return (v && v > 0) ? v : SPEED_PRESETS[0].speed;
    }

    // ---- stick + keys -------------------------------------------

    _stickDown(e) {
      if (!this.marker) { this._readout('Click the map to drop the device first.'); return; }
      if (this.replay) this._endReplay('Replay cancelled — you took the wheel.');
      this.stickPointer = e.pointerId;
      e.currentTarget.setPointerCapture(e.pointerId);
      this._stickMove(e);
    }

    _stickMove(e) {
      if (this.stickPointer !== e.pointerId) return;
      const rect = e.currentTarget.getBoundingClientRect();
      const radius = rect.width / 2;
      const dx = e.clientX - (rect.left + radius);
      const dy = e.clientY - (rect.top + radius);
      const dist = Math.hypot(dx, dy);
      const magnitude = Math.min(dist / radius, 1);

      if (magnitude < DEADZONE) {
        this._thumbTo(0, 0);
        this.stickSpeed = 0;
        this._applyVector();
        return;
      }
      // Clamp the thumb to the pad edge, and rescale the live range so
      // the speed ramps from 0 at the deadzone edge rather than jumping.
      const clamped = Math.min(dist, radius);
      this._thumbTo(dx / dist * clamped, dy / dist * clamped);
      const scaled = (magnitude - DEADZONE) / (1 - DEADZONE);
      // The stick is absolute: it points the device outright, and the
      // heading it sets is the one W/S will drive along afterwards.
      this.heading = bearingOf(dx, dy);
      this.stickSpeed = scaled * this._presetSpeed();
      this._applyVector();
    }

    _stickUp(e) {
      if (this.stickPointer !== e.pointerId) return;
      this.stickPointer = null;
      this.stickSpeed = 0;
      this._thumbTo(0, 0);
      this._applyVector();
    }

    _thumbTo(x, y) {
      const thumb = this.host && this.host.querySelector('#nativeLocationThumb');
      if (thumb) thumb.style.transform = `translate(${x}px, ${y}px)`;
    }

    _keyDown(e) {
      if (this.mode !== 'walk' || !this._keysWelcome(e)) return;
      if (e.key === 'Shift') { this.boost = true; this._applyVector(); return; }
      const role = KEY_ROLES[e.code];
      if (!role) return;
      e.preventDefault();          // arrows would otherwise scroll the panel
      if (!this.marker) { this._readout('Click the map to drop the device first.'); return; }
      if (this.replay) this._endReplay('Replay cancelled — you took the wheel.');
      // Opposite keys: last press wins rather than cancelling, so
      // rocking W↔S reverses cleanly instead of stalling.
      this[role[0]] = role[1];
      this._applyVector();
      this._ensureLoop();
    }

    _keyUp(e) {
      if (e.key === 'Shift') { this.boost = false; this._applyVector(); return; }
      const role = KEY_ROLES[e.code];
      if (!role) return;
      // Only clear if this key still owns the axis — releasing W after
      // rocking onto S must not cancel S.
      if (this[role[0]] === role[1]) this[role[0]] = 0;
      this._applyVector();
    }

    // Don't steal keys from a field the user is typing in — the place
    // search sits inches above the stick.
    _keysWelcome(e) {
      const t = e.target;
      if (!t) return true;
      const tag = t.tagName;
      return tag !== 'INPUT' && tag !== 'TEXTAREA' && tag !== 'SELECT' && !t.isContentEditable;
    }

    _releaseAll() {
      this.throttle = 0;
      this.turn = 0;
      this.boost = false;
      this.stickPointer = null;
      this.stickSpeed = 0;
      this._thumbTo(0, 0);
      this._applyVector();
    }

    // Compose the vector from the persistent heading plus whatever is
    // currently held. The stick wins while it's being dragged (it sets
    // the heading outright); otherwise the throttle drives along the
    // heading — forward on W, reversed 180° on S, exactly like backing a
    // car up: you still face the same way, you just travel the other.
    _applyVector() {
      if (this.stickPointer !== null) {
        this._setVector(this.stickSpeed > 0
          ? { bearing: this.heading, speed: this.stickSpeed }
          : null);
        return;
      }
      if (!this.throttle) { this._setVector(null); return; }
      this._setVector({
        bearing: (this.heading + (this.throttle < 0 ? 180 : 0)) % 360,
        speed: this._presetSpeed() * (this.boost ? BOOST : 1),
      });
    }

    // The walk loop runs while anything is live — moving, mid-turn (you
    // can pivot on the spot), or replaying.
    _walkActive() {
      return !!this.walkVector || this.turn !== 0 || !!this.replay;
    }

    _ensureLoop() {
      if (this._walkActive()) this._tick();
    }

    // ---- the walk itself ----------------------------------------

    // Adopt a new vector (or `null` to stop). Re-origins the reckoning at
    // wherever the pin has reached, so the next leg starts from the
    // device's believed position rather than the last one we sent.
    _setVector(vector) {
      const was = this.walkVector;
      if (!vector && !was) { this._paintCompass(); return; }
      const here = this._livePosition();
      this.walkOrigin = here;
      this.walkOriginAt = performance.now();
      this.walkVector = vector;

      if (vector) {
        this._ensureLoop();
        this._send();
      } else {
        this._stop(here);
      }
      this._paintCompass();
      this._syncReplay();
    }

    // Where we believe the device is *now*: the last origin, dead-reckoned
    // forward along the vector by the time since we stamped it.
    _livePosition() {
      if (!this.walkVector || !this.walkOrigin) {
        if (this.marker) {
          const p = this.marker.getLatLng();
          return { lat: p.lat, lon: p.lng };
        }
        return this.walkOrigin;
      }
      const seconds = (performance.now() - this.walkOriginAt) / 1000;
      return project(
        this.walkOrigin.lat, this.walkOrigin.lon,
        this.walkVector.bearing, this.walkVector.speed * seconds
      );
    }

    _tick() {
      // Idempotent by contract: exactly one frame may ever be pending.
      // Without this guard the loop forks — `_applyVector` inside the
      // tick calls `_ensureLoop`, which schedules a frame, and then the
      // end of that same tick schedules another. Two chains integrating
      // one heading turned A/D at double the rate they claimed.
      if (this.frame) return;
      this.frame = requestAnimationFrame(() => {
        this.frame = null;
        const now = performance.now();
        // Integrate the turn against real elapsed time, not per frame, so
        // the sweep is the same speed on a 60 Hz and a 120 Hz display.
        // Clamped: a backgrounded tab resumes with a huge gap that would
        // otherwise spin the heading wildly on the first frame back.
        const dt = Math.min((now - (this.lastFrameAt || now)) / 1000, 0.1);
        this.lastFrameAt = now;

        if (this.turn && !this.replay) {
          this.heading = (this.heading + this.turn * TURN_RATE * dt + 360) % 360;
          this._applyVector();       // re-origins, so a turn traces an arc
        }

        if (this.replay) {
          this._stepReplay(now);
        } else if (this.walkVector && this.marker) {
          const here = this._livePosition();
          const latlng = L.latLng(here.lat, here.lon);
          this.marker.setLatLng(latlng);
          this._traceTrail(here, latlng);
          this._keepInView(latlng);
          this._readWalk(here);
          // The frame loop is also the send pump. `_send` is cheap and
          // self-rate-limiting, and pumping it here means a change that
          // got rate-limited retries on the next frame instead of
          // stalling until something else happens to call it.
          this._send();
        }

        this._paintCompass();
        if (this._walkActive()) this._tick();
        else this.lastFrameAt = 0;
      });
    }

    // Record the path as both a polyline (to see) and points (to replay).
    // Sampled by distance, not by frame: at 60 fps a minute's walk would
    // otherwise be 3,600 points — a bloated polyline and a replay body
    // far past the server's 64 KB limit.
    _traceTrail(here, latlng) {
      const last = this.trail[this.trail.length - 1];
      if (last && distanceBetween(last, here) < TRAIL_MIN_METRES) return;
      this.trail.push({ lat: here.lat, lon: here.lon });

      // Long walk? Halve the resolution rather than dropping the tail —
      // a coarser record of the whole route beats a crisp record of its
      // first half.
      if (this.trail.length > TRAIL_MAX_POINTS) {
        this.trail = this.trail.filter((_, i) => i % 2 === 0);
        if (this.walkTrail) {
          this.walkTrail.setLatLngs(this.trail.map((p) => L.latLng(p.lat, p.lon)));
        }
      }
      if (!this.walkTrail) {
        this.walkTrail = L.polyline([latlng], { color: '#22c55e', weight: 2, opacity: 0.7 })
          .addTo(this.map);
      } else {
        this.walkTrail.addLatLng(latlng);
      }
      this._syncReplay();
    }

    // Pan once the pin nears the edge, rather than every frame — a
    // constant re-centre makes the tiles fight the user's own panning.
    _keepInView(latlng) {
      if (!this.map.getBounds().pad(-0.25).contains(latlng)) {
        this.map.panTo(latlng, { animate: true, duration: 0.4 });
      }
    }

    // The needle always shows the *persistent heading*, moving or not.
    // It used to fall back to 0° whenever the vector went null, so
    // releasing the stick swung the needle round to north — and, with a
    // transition on the transform, it slewed there rather than holding.
    // The device still points somewhere when it's standing still.
    _paintCompass() {
      const needle = this.host && this.host.querySelector('#nativeLocationNeedle');
      const course = this.host && this.host.querySelector('#nativeLocationCourse');
      const stick = this.host && this.host.querySelector('#nativeLocationStick');
      const v = this.walkVector;
      const heading = Math.round(this.heading);
      if (needle) {
        needle.style.transform = `rotate(${this.heading}deg)`;
        needle.classList.toggle('moving', !!v);
      }
      if (course) {
        const reversing = v && this.throttle < 0;
        course.textContent = v
          ? `${heading}° ${cardinalOf(this.heading)} · ${v.speed.toFixed(1)} m/s${reversing ? ' ⟲' : ''}`
          : `${heading}° ${cardinalOf(this.heading)} · stopped`;
      }
      if (stick) {
        stick.setAttribute('aria-valuenow', heading);
        stick.setAttribute('aria-valuetext', v
          ? `heading ${heading} degrees ${cardinalOf(this.heading)}, ${v.speed.toFixed(1)} metres per second`
          : `heading ${heading} degrees ${cardinalOf(this.heading)}, stopped`);
      }
    }

    _readWalk(here) {
      const v = this.walkVector;
      this._readout(`${round6(here.lat)}, ${round6(here.lon)}`
        + (v ? `  →  course ${Math.round(v.bearing)}° ${cardinalOf(v.bearing)}` : ''));
    }

    // ---- sending -------------------------------------------------

    // Serialise every location POST this panel makes through one chain.
    // Ordering is not optional here: a stop that overtook an in-flight
    // vector would land first, the vector would apply *after* it, and the
    // device would walk away with the stick already released and nothing
    // left to stop it. `_post` swallows its own errors, so a failed link
    // can't break the chain.
    _chain(work) {
      this.tail = (this.tail || Promise.resolve()).then(work, work);
      return this.tail;
    }

    // Latest-wins. A send is a ~430 ms spawn, so we never queue: if the
    // vector moves while one is in flight, we flag it and send the newest
    // value once the wire frees up. Anything in between is stale by
    // definition — the stick has already moved on.
    _send() {
      if (!this.walkVector || !this.walkOrigin) return;
      if (this.sendInFlight) { this.sendPending = true; return; }
      if (!this._worthSending()) return;

      const vector = this.walkVector;
      const origin = this.walkOrigin;
      this.sendInFlight = true;
      this.lastSentAt = performance.now();
      this.walkSentVector = vector;

      this._chain(() => this._post({
        latitude: round6(origin.lat),
        longitude: round6(origin.lon),
        bearing: round6(vector.bearing),
        speed: round6(vector.speed),
      }, { quiet: true })).finally(() => {
        this.sendInFlight = false;
        if (this.sendPending) { this.sendPending = false; this._send(); }
      });
    }

    // Skip sends the device couldn't tell apart, and rate-limit the rest.
    // The keepalive path deliberately bypasses the equality check — an
    // unchanged vector still needs re-sending before its route runs out.
    _worthSending() {
      const now = performance.now();
      const sent = this.walkSentVector;
      if (!sent) return true;                                    // first leg since a stop
      if (now - this.lastSentAt > KEEPALIVE_MS) return true;     // route running out of road
      if (now - this.lastSentAt < SEND_INTERVAL_MS) return false;
      const v = this.walkVector;
      // Compare the turn the short way round the circle: 359° and 1° are
      // 2° apart, not 358°.
      const turned = Math.abs(((v.bearing - sent.bearing + 540) % 360) - 180) > BEARING_EPSILON;
      return turned || Math.abs(v.speed - sent.speed) > SPEED_EPSILON;
    }

    // Releasing the stick pins the device exactly where the pin sits.
    // A plain point `set` both stops the route and drops course back to
    // -1, which is precisely "no longer travelling" — and it re-syncs
    // away any lag the in-flight spawns built up.
    //
    // Goes through the chain so it lands *after* any vector still in
    // flight, and clears `sendPending` so a vector queued before the
    // release can't fire behind it.
    _stop(here) {
      this.walkSentVector = null;
      this.sendPending = false;
      if (!here) return;
      this._chain(() =>
        this._post({ latitude: round6(here.lat), longitude: round6(here.lon) }, { quiet: true })
          .then(() => this._readout(`Stopped at ${round6(here.lat)}, ${round6(here.lon)}`)));
    }

    // ---- replay -------------------------------------------------

    // Replay retraces the path you just walked. The recorded trail *is*
    // a `{waypoints,speed}` route body — the exact shape Route mode
    // already posts — so this reuses the existing `simctl location start`
    // path end to end with no new wire and no new Swift.
    //
    // The speed comes from the preset at replay time rather than from
    // what you originally walked: simctl's `start` takes one speed for a
    // whole route, so a varying-speed walk can't be reproduced exactly
    // anyway — and choosing at replay time means you can retrace a
    // footpath at Highway speed, which turns out to be the useful part.
    _replay() {
      if (this.trail.length < 2 || this.replay) return;
      this._releaseAll();
      const speed = this._presetSpeed();
      const points = this.trail.slice();

      this._chain(() => this._post({
        waypoints: points.map((p) => ({ latitude: round6(p.lat), longitude: round6(p.lon) })),
        speed: round6(speed),
      }, { quiet: true }));

      // Precompute the cumulative distance so each frame is a lookup
      // rather than a walk of the whole polyline.
      const legs = [];
      let total = 0;
      for (let i = 1; i < points.length; i++) {
        total += distanceBetween(points[i - 1], points[i]);
        legs.push(total);
      }
      this.replay = { points, legs, total, speed, startedAt: performance.now() };
      this._readout(`Replaying ${points.length} points at ${speed} m/s…`);
      this._syncReplay();
      this._ensureLoop();
    }

    // Walk the pin along the recorded trail so the map shows the replay
    // the device is running. The device is interpolating the same
    // waypoints at the same speed, so the two track together.
    _stepReplay(now) {
      const r = this.replay;
      const travelled = (now - r.startedAt) / 1000 * r.speed;
      if (travelled >= r.total) {
        const end = r.points[r.points.length - 1];
        this._placePin(end);
        this.heading = r.points.length > 1
          ? bearingBetween(r.points[r.points.length - 2], end)
          : this.heading;
        this._endReplay('Replay complete.');
        return;
      }
      let i = r.legs.findIndex((d) => d >= travelled);
      if (i < 0) i = r.legs.length - 1;
      const from = r.points[i];
      const to = r.points[i + 1];
      const legStart = i === 0 ? 0 : r.legs[i - 1];
      const into = travelled - legStart;
      const bearing = bearingBetween(from, to);
      const at = project(from.lat, from.lon, bearing, into);
      this.heading = bearing;          // the needle turns through the replay
      this._placePin(at);
      this._readout(`Replaying… ${Math.round(travelled)} / ${Math.round(r.total)} m`);
    }

    _placePin(p) {
      const latlng = L.latLng(p.lat, p.lon);
      if (this.marker) this.marker.setLatLng(latlng);
      this._keepInView(latlng);
      this.walkOrigin = { lat: p.lat, lon: p.lon };
      this.walkOriginAt = performance.now();
    }

    _endReplay(message) {
      this.replay = null;
      if (message) this._readout(message);
      this._syncReplay();
      this._paintCompass();
    }

    // The Replay button only makes sense with a path to retrace and
    // nothing else going on.
    _syncReplay() {
      const btn = this.host && this.host.querySelector('#nativeLocationReplay');
      if (!btn) return;
      btn.disabled = this.trail.length < 2 || !!this.walkVector;
      btn.textContent = this.replay ? 'Stop replay' : 'Replay';
    }

    _drawRoute() {
      const pts = this.routePins.map((m) => m.getLatLng());
      if (this.routeLine) { this.map.removeLayer(this.routeLine); this.routeLine = null; }
      if (pts.length >= 2) {
        this.routeLine = L.polyline(pts, { color: '#3b82f6', weight: 3 }).addTo(this.map);
      }
      this._readout(`${pts.length} waypoint${pts.length === 1 ? '' : 's'} — `
        + (pts.length >= 2 ? 'ready to start.' : 'add at least one more.'));
    }

    _readPoint(latlng) {
      this._readout(`${round6(latlng.lat)}, ${round6(latlng.lng)}`);
    }

    _readout(text) {
      const el = this.host && this.host.querySelector('#nativeLocationReadout');
      if (el) el.textContent = text;
    }

    _syncApply() {
      const apply = this.host.querySelector('#nativeLocationApply');
      if (!apply) return;
      apply.disabled = (this.mode === 'route')
        ? this.routePins.length < 2
        : !this.marker;
    }

    // ---- send ----------------------------------------------------

    _apply() {
      if (this.mode !== 'route') {
        // Point and Walk share this: pin the device where the marker is.
        // In Walk mode that's how you place the device before driving it.
        if (!this.marker) return;
        const { lat, lng } = this.marker.getLatLng();
        this._post({ latitude: round6(lat), longitude: round6(lng) });
      } else {
        if (this.routePins.length < 2) return;
        const waypoints = this.routePins.map((m) => {
          const p = m.getLatLng();
          return { latitude: round6(p.lat), longitude: round6(p.lng) };
        });
        const body = { waypoints };
        const speed = parseFloat(this.host.querySelector('#nativeLocationSpeed').value);
        if (!isNaN(speed) && speed > 0) body.speed = speed;
        this._post(body);
      }
    }

    // Returns the fetch promise so Walk mode can chain its latest-wins
    // send loop off it. `quiet` suppresses the success readout: a walk
    // repaints the live position every frame and must not have it
    // stomped by a "sent ✓" from an in-flight vector.
    _post(body, { quiet = false } = {}) {
      return fetch(`/devices/${encodeURIComponent(this.udid)}/location`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      }).then((res) => {
        if (!res.ok) this._readout('Location failed — is the device booted?');
        else if (!quiet) this._readout('Location sent ✓');
        return res;
      }).catch(() => this._readout('Location failed — network error.'));
    }

    _clear() {
      fetch(`/devices/${encodeURIComponent(this.udid)}/location`, { method: 'DELETE' })
        .then((res) => this._readout(res.ok ? 'Cleared — live location restored.' : 'Clear failed.'))
        .catch(() => this._readout('Clear failed — network error.'));
      this._reset();
    }
  }

  window.LocationPanel = LocationPanel;
})();
