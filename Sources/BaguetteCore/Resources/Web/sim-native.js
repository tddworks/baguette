// sim-native.js — focus mode at /simulators/<udid>.
//
// Activates only when the page is loaded directly with a UDID in the
// path. Renders a macOS-Simulator-style window chrome (traffic
// lights, centered device title, top-right Home / Screenshot / Lock
// toolbar) wrapping a focused live-stream surface. Reuses the same
// modules as sim-stream.js — DeviceFrame, FrameDecoder, StreamSession,
// SimInput, MouseGestureSource, PinchOverlay — without the sidebar.
//
// Sets `window.__baguetteNativeMode = true` *synchronously* so
// sim-list.js (loaded later) can early-return and not paint the list
// underneath us.
(function () {
  'use strict';

  // --- Activation gate ---------------------------------------------
  // Match `/simulators/<udid>`; reject `/simulators` and
  // `/simulators/`. UDIDs never contain `/`, so the second segment
  // being non-empty is the discriminator.
  function deepLinkUdid() {
    const parts = location.pathname.split('/').filter(Boolean);
    if (parts.length !== 2) return null;
    if (parts[0] !== 'simulators') return null;
    const u = decodeURIComponent(parts[1]);
    if (!u) return null;
    return u;
  }

  const udid = deepLinkUdid();
  if (!udid) return; // not deep-link mode; let sim-list run.
  window.__baguetteNativeMode = true;

  // --- State -------------------------------------------------------
  let session = null;
  let sim = null;           // Baguette SDK Simulator
  let logPanel = null;
  let axInspector = null;
  let cameraPanel = null;   // CameraPanel — Mac webcam → /tmp/SimCam.bgra
  let statusBarPanel = null; // StatusBarPanel — simctl status_bar overrides
  let lastPaintedSize = { w: 0, h: 0 };
  let deviceName = '';

  // CW rotation cycle. Two flavours — iPhone UIKit refuses
  // `portrait-upside-down` for apps that don't opt in (which is
  // basically every Apple-shipped iPhone app), so the cycle skips
  // it on phones to keep every click visibly productive. iPads
  // and other tablet-class devices honour all four. The Domain /
  // CLI / HTTP layers still accept `portrait-upside-down`
  // unconditionally — this trim is UI ergonomics only.
  // Starting index is `0` (portrait); we don't probe the guest
  // because the GSEvent path is write-only.
  // Every wire-name `DeviceOrientation` accepts is reachable from
  // the rotate-button cycle, on phones and tablets alike. The
  // order matches a true 90°-clockwise visual rotation per click:
  //   portrait              (CSS rotate(0))
  //   landscape-left        (CSS rotate(90deg)   — home on left of visual)
  //   portrait-upside-down  (CSS rotate(180deg))
  //   landscape-right       (CSS rotate(-90deg)  — home on right of visual)
  // Names refer to *home-button position* on the rotated bezel
  // (Apple's UIDeviceOrientation convention), not direction of
  // rotation — which is why `landscape-left` comes first in a
  // clockwise cycle. iPhone UIKit silently ignores
  // `portrait-upside-down` for apps that don't declare the
  // interface orientation; the cycle still exposes it so apps
  // that *do* honour it are reachable.
  const ORIENTATION_CYCLE = [
    'portrait', 'landscape-left', 'portrait-upside-down', 'landscape-right',
  ];
  let orientationIndex = 0;
  let currentOrientation = 'portrait';

  // Debug knobs for landscape-right edge-gesture exploration —
  // iOS in raw=3 doesn't fire the home recognizer on any of the
  // recipes that work for landscape-left / upside-down, so we
  // expose runtime overrides so the next drag uses a different
  // (edge, coord) combination without a rebuild.
  //   window.__edgeOverride('top'|'right'|'bottom'|'left'|null)
  //   window.__mirrorX(true|false)         — flip portrait_x via {x: y, y: x}
  //   window.__lrConfig()                  — print current state
  //   window.__lrReset()                   — restore defaults
  let lrEdgeOverride = null;     // null → use the default mapping
  let lrMirrorX      = false;    // false → strict CSS-rotation inverse
  if (typeof window !== 'undefined') {
    window.__edgeOverride = (e) => { lrEdgeOverride = e || null; console.log('[lr] edge override =', lrEdgeOverride); };
    window.__mirrorX      = (b) => { lrMirrorX = !!b;             console.log('[lr] mirror-X =', lrMirrorX); };
    window.__lrReset      = ()  => { lrEdgeOverride = null; lrMirrorX = false; console.log('[lr] reset'); };
    window.__lrConfig     = ()  => { console.log('[lr]', { edgeOverride: lrEdgeOverride, mirrorX: lrMirrorX }); };
  }
  // Absolute rotation degrees, monotonically increasing — each
  // rotate-button click adds 90. Applied inline so CSS transitions
  // interpolate the *short* way (always +90° forward) instead of
  // the long way around when the wire-name's canonical angle
  // would have decreased (e.g. 180° → -90° = -270° animation
  // would be visibly weird). Modulo 360 just keeps the number
  // tidy; the transition driver doesn't care about absolute size.
  let rotationDegrees = 0;

  function orientationCycle() {
    return ORIENTATION_CYCLE;
  }

  // Apply orientation visually: set the inline `transform` on the
  // device-frame wrapper, plus a `data-orientation` attribute on
  // the container so non-rotation CSS (max-height caps in
  // landscape) and the input/overlay coord transforms can read
  // `currentOrientation`.
  function applyOrientation(value) {
    const previous = currentOrientation;
    currentOrientation = value;
    const root = document.getElementById('nativeDeviceFrame');
    if (root) {
      if (value === 'portrait') root.removeAttribute('data-orientation');
      else                      root.setAttribute('data-orientation', value);
      // Advance the rotation by one cycle step (90° CW) when we
      // move forward in the cycle. If the caller asked for the
      // same orientation we already display (e.g. session restart
      // after format swap), keep the existing degrees so the
      // bezel doesn't re-animate.
      if (value !== previous) {
        rotationDegrees += 90;
      }
      const wrapper = root.querySelector(':scope > div');
      if (wrapper) wrapper.style.transform = 'rotate(' + rotationDegrees + 'deg)';
    }
  }

  // Map a normalized coord [0, 1]² from the rotated visual frame
  // back to the device's portrait coord system. Used by the input
  // transport so taps/swipes/touches land on the iOS element the
  // user clicked on, even though iOS expects portrait coords.
  // Direction must mirror the CSS transforms in sim-native.html —
  // landscape-right is rotate(-90deg) (CCW) on the wrapper, so the
  // visual→portrait inverse rotates CW.
  function visualToPortraitNorm(x, y) {
    switch (currentOrientation) {
      case 'landscape-right':       return { x: 1 - y,     y: x         };
      case 'portrait-upside-down':  return { x: 1 - x,     y: 1 - y     };
      case 'landscape-left':        return { x: y,         y: 1 - x     };
      default:                      return { x,            y            };
    }
  }

  // Remap a Baguette-wire envelope from the rotated visual frame
  // to the device's portrait coord frame. The Baguette SDK's
  // PointerInterpreter computes finger coords against screenArea's
  // bounding rect, which after CSS rotation is the ROTATED bbox —
  // so the chrome-pixel coords in each envelope are in the user's
  // visual frame. iOS expects portrait coords, so we rotate them
  // before the WebSocket send.
  //
  // Replaces the legacy `remapPayloadToPortrait` (operated on the
  // SimInput `kind:` dialect) with the same logic on the new
  // `type:` envelopes.
  function remapEnvelopeToPortrait(p) {
    if (!p || !p.type) return p;
    const W = p.width || 0, H = p.height || 0;
    const remapPx = (x, y) => {
      if (!W || !H) return { x, y };
      const r = visualToPortraitNorm(x / W, y / H);
      return { x: r.x * W, y: r.y * H };
    };
    switch (p.type) {
      case 'tap': {
        const r = remapPx(p.x, p.y);
        return { ...p, x: r.x, y: r.y };
      }
      case 'swipe': {
        const a = remapPx(p.startX, p.startY);
        const b = remapPx(p.endX,   p.endY);
        return { ...p, startX: a.x, startY: a.y, endX: b.x, endY: b.y };
      }
      case 'touch1-down':
      case 'touch1-move':
      case 'touch1-up': {
        const r = remapPx(p.x, p.y);
        const env = { ...p, x: r.x, y: r.y };
        if (p.edge) env.edge = visualToPortraitEdge(p.edge);
        return env;
      }
      case 'touch2-down':
      case 'touch2-move':
      case 'touch2-up': {
        const a = remapPx(p.x1, p.y1);
        const b = remapPx(p.x2, p.y2);
        return { ...p, x1: a.x, y1: a.y, x2: b.x, y2: b.y };
      }
      default:
        return p;
    }
  }

  // Map a screen-edge name from the user's visual frame to the
  // device's portrait coord frame. When the device is rotated, the
  // user's visual bottom corresponds to a *different* physical
  // edge in portrait coords (the frame the digitizer dispatch
  // patches `IndigoHIDEdge` against). Without this remap, a swipe
  // up from the visual bottom in landscape lands as portrait coords
  // near the left/right edge but is still flagged `bottom` — iOS's
  // gesture recognizer requires the flag to match the touch's
  // physical edge, so the home gesture never fires.
  //
  //   portrait                : visual bottom → physical bottom
  //   landscape-right         : visual bottom → physical left
  //   portrait-upside-down    : visual bottom → physical top
  //   landscape-left          : visual bottom → physical right
  //
  // Same rotation applies to all four edge names — derived from
  // the same CSS rotate transforms the bezel uses.
  function visualToPortraitEdge(edge) {
    if (!edge) return edge;
    // Empirical mapping (verified against iOS 26.4 home-indicator
    // recognizer in our headless setup):
    //   portrait                : bottom → bottom
    //   landscape-left  (raw=4) : bottom → right   (rotateCW; verified)
    //   landscape-right (raw=3) : bottom → left    (rotateCCW; recognizer not wired — known limitation)
    //   portrait-upside-down    : bottom → right   (matches raw=4 path; verified)
    //
    // iOS rotates the home-indicator recognizer hot zone with
    // orientation for raw=4 and raw=2 — both end up at
    // portrait-right + edge=right. raw=3 *should* mirror to
    // portrait-left + edge=left by the same logic, but iOS
    // doesn't fire the recognizer there in our headless setup
    // (the well-documented landscape-right gap). Sending edge=left
    // keeps the wire envelope physically self-consistent (touch
    // coords land on portrait-left, edge flag agrees) so the
    // gesture isn't mis-routed to a different system region.
    // Empirical mapping (verified):
    //   portrait              : bottom → bottom  (✅ home fires)
    //   landscape-left  (raw=4): bottom → right  (✅ home fires)
    //   portrait-upside-down  : bottom → right  (✅ home fires)
    //   landscape-right (raw=3): bottom → top    (✅ home fires)
    switch (currentOrientation) {
      case 'landscape-left':       return edge === 'bottom' ? 'right' : edge;
      case 'portrait-upside-down': return edge === 'bottom' ? 'right' : edge;
      case 'landscape-right':      return edge === 'bottom' ? 'top' : edge;
      default:                     return edge;
    }
  }

  // --- Bootstrap ---------------------------------------------------
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
  } else {
    boot();
  }

  async function boot() {
    // Reset whatever sim.html landed with. Body gets `margin:0;
    // overflow:hidden;` so the focus-mode UI fills the viewport,
    // but the *background* is left to the focus-mode stylesheet —
    // it tracks the user's prefers-color-scheme via CSS variables,
    // so hardcoding a colour here would defeat the theme switch.
    document.body.innerHTML = '';
    document.body.style.cssText = 'margin:0;padding:0;overflow:hidden';
    // Match <body> background to the active focus-mode page bg so
    // the page never flashes white during theme transitions or
    // before the template paints.
    document.body.style.background = 'var(--nv-page-bg, #1a1a1f)';

    // 1. Load template + inline styles from sim-native.html.
    const html = await fetchTemplate();
    if (!html) {
      document.body.innerHTML =
          '<pre style="color:#f87171;padding:24px;font-family:ui-monospace">sim-native.html not found</pre>';
      return;
    }
    document.body.insertAdjacentHTML('beforeend', html);

    // 2. Resolve device name + iOS runtime from the list endpoint.
    //    The SDK definition gives us the bezel; /simulators.json gives
    //    us the human-readable identity that sits above it.
    const meta = await fetchDeviceMeta(udid);
    deviceName = meta.name;
    const nameEl = document.getElementById('nativeDeviceName');
    const osEl = document.getElementById('nativeDeviceOS');
    if (nameEl) nameEl.textContent = meta.name;
    if (osEl)   osEl.textContent   = meta.runtime;
    document.title = `${meta.name} — Baguette`;

    // 3. Boot the Baguette SDK. It fetches `/definition.json`,
    //    builds the bezel + overlay buttons + screen + keyboard,
    //    and mounts everything interactive. The `send` closure
    //    routes wire envelopes through the StreamSession's
    //    WebSocket — but BEFORE forwarding it remaps coords and
    //    edge flags from the rotated visual frame to portrait
    //    (iOS expects portrait coords regardless of the bezel's
    //    CSS rotation).
    sim = await window.Baguette.use({
      host: location.origin,
      udid,
      send: (payload) => {
        if (!session) return;
        const out = currentOrientation === 'portrait'
          ? payload
          : remapEnvelopeToPortrait(payload);
        session.send(out);
      },
      getOrientation: () => currentOrientation,
      log: (msg) => console.log('[native]', msg),
    });
    sim.mount(document.getElementById('nativeDeviceFrame'));

    // 4. Open stream — paints frames into sim.canvas.
    startSession(pickFormat());

    wireActions();
    wireUnload();
    applyStoredTheme();

    // Reset iOS to portrait on page boot. Without this, a page
    // reload would leave our JS state at `currentOrientation =
    // 'portrait'` (rotation degrees 0) while iOS still holds
    // whatever orientation it was set to in a previous session
    // — the bezel renders un-rotated but the iOS framebuffer
    // shows UI from the stale orientation, which looks upside
    // down to the user.
    fetch('/simulators/' + encodeURIComponent(udid) + '/orientation?value=portrait',
        { method: 'POST' }).catch(() => { /* best-effort */ });
  }

  // Theme toggle. Three logical states — "auto" (no manual pin,
  // follow OS via prefers-color-scheme), "light", "dark". The pill
  // in the bottom-right corner cycles light ↔ dark; we don't
  // expose "auto" from the click cycle because the icon set has
  // only two states. The user can reset to auto by deleting the
  // localStorage key in DevTools if needed.
  const THEME_KEY = 'baguette.simTheme';

  function applyStoredTheme() {
    const stored = localStorage.getItem(THEME_KEY);
    if (stored === 'light' || stored === 'dark') {
      setTheme(stored);
    }
  }

  function currentTheme() {
    const root = document.getElementById('simNativeView');
    const pinned = root && root.getAttribute('data-theme');
    if (pinned === 'light' || pinned === 'dark') return pinned;
    return window.matchMedia('(prefers-color-scheme: light)').matches
        ? 'light' : 'dark';
  }

  function setTheme(theme) {
    const root = document.getElementById('simNativeView');
    if (!root) return;
    if (theme === 'light' || theme === 'dark') {
      root.setAttribute('data-theme', theme);
      localStorage.setItem(THEME_KEY, theme);
    } else {
      root.removeAttribute('data-theme');
      localStorage.removeItem(THEME_KEY);
    }
  }

  // Open (or reopen) a StreamSession on the existing surface for a
  // given wire format. Tearing down + restarting is the cheapest way
  // to swap formats — the WS protocol is per-connection and the
  // server's makeStream(...) is keyed at session open.
  function startSession(format) {
    if (session) { try { session.stop(); } catch (_) {} session = null; }
    // Same text-frame router as sim-stream.js: hand JSON envelopes
    // to the inspector first; anything it doesn't claim falls
    // through to the decoder's error logger.
    const onStreamText = (env) => {
      if (axInspector && axInspector.handleEnvelope(env)) return true;
      return false;
    };
    session = new window.StreamSession({
      udid, format, version: 'v2',
      canvas: sim.canvas,
      onSize: (w, h) => { lastPaintedSize = { w, h }; },
      onFps:  (fps) => {
        const el = document.getElementById('nativeStatus');
        if (el) el.textContent = fps + ' fps';
      },
      onLog: (msg) => console.log('[native]', msg),
      onText: onStreamText,
    });
    session.start();
    reflectFormat(format);
    // Restore the cached orientation across format-swap remounts,
    // so reopening the session doesn't snap the device back to
    // portrait while the simulator is still landscape.
    if (currentOrientation !== 'portrait') applyOrientation(currentOrientation);
    mountAxInspector();
  }

  // Lazy-mounts the AXInspector once a surface + session are ready.
  // Re-runs on `remountFrame()` because the screen DOM and the
  // session both change underneath it.
  //
  // Focus-mode UX:
  //   - The inspector has no inline UI host. Enable/disable is
  //     driven by the `nativeAxToggle` toolbar button.
  //   - Selection details surface in the `nativeAxHost` floating
  //     panel, which is hidden until the user clicks an element.
  function mountAxInspector() {
    if (axInspector) {
      try { axInspector.detach(); } catch (_) { /* ignore */ }
      axInspector = null;
    }
    if (!window.AXInspector || !sim) return;
    const panel = document.getElementById('nativeAxHost');
    axInspector = new window.AXInspector({
      // No `host` — toolbar drives enable/disable, panel surfaces selection.
      screenArea: sim.screenArea,
      send: (payload) => session && session.send(payload),
      // AX inspector reads `{w, h}`; SDK Screen exposes `{width, height}`.
      getDeviceSize: () => ({ w: sim.screen.size.width, h: sim.screen.size.height }),
      onSelect: (node) => renderAxPanel(panel, node),
      onEnableChange: (enabled) => {
        const btn = document.getElementById('nativeAxToggle');
        if (btn) btn.classList.toggle('active', enabled);
        if (!enabled && panel) {
          panel.removeAttribute('data-open');
          panel.innerHTML = '';
        }
      },
    });
  }

  function reflectFormat(format) {
    document.querySelectorAll('#nativeFormatPicker .fmt-btn').forEach((b) => {
      b.classList.toggle('active', b.dataset.v === format);
    });
  }

  // --- Helpers -----------------------------------------------------
  let _templatePromise = null;
  function fetchTemplate() {
    if (_templatePromise) return _templatePromise;
    _templatePromise = fetch('/sim-native.html')
        .then((r) => (r.ok ? r.text() : ''))
        .then((html) => {
          if (!html) return '';
          const doc = new DOMParser().parseFromString(html, 'text/html');
          // Carry the inline <style> blocks (they live in <body>) plus
          // the #simNativeView root. The standalone-preview <script>
          // is ignored — boot() owns the wiring instead.
          const styles = Array.from(doc.body.querySelectorAll('style'))
              .map((s) => s.outerHTML).join('\n');
          const root = doc.getElementById('simNativeView');
          return styles + (root ? root.outerHTML : '');
        })
        .catch(() => '');
    return _templatePromise;
  }

  async function fetchDeviceMeta(targetUdid) {
    try {
      const r = await fetch('/simulators.json', { cache: 'no-store' });
      if (!r.ok) throw new Error(String(r.status));
      const json = await r.json();
      const all = (json.running || []).concat(json.available || []);
      const hit = all.find((d) => (d.id || d.udid) === targetUdid);
      if (hit) {
        return {
          name: hit.name || 'Simulator',
          runtime: hit.displayRuntime
              || formatRuntime(hit.runtime || hit.os || ''),
        };
      }
    } catch (_) { /* fall through */ }
    return { name: 'Simulator', runtime: '' };
  }

  function formatRuntime(raw) {
    return String(raw || '')
        .replace('com.apple.CoreSimulator.SimRuntime.', '')
        .replace(/^iOS-/, 'iOS ')
        .replace(/-/g, '.');
  }

  function pickFormat() {
    const stored = localStorage.getItem('asc.simFormat');
    if (stored === 'avcc' || stored === 'mjpeg') return stored;
    return window.FrameDecoder && window.FrameDecoder.isHardwareAvailable()
        ? 'avcc' : 'mjpeg';
  }

  function wireActions() {
    window.__nativeHome = () => sim && sim.pressButton('home');
    // App switcher — fires the new `app-switcher` virtual button
    // on the server side. The Swift `IndigoHIDInput` decomposes it
    // into two consecutive home `IndigoHIDMessageForButton` presses
    // ~150 ms apart, which is the recipe SpringBoard listens for
    // (works on Face ID iPhones with no physical home button). No
    // gesture coordinates involved, so device rotation is a non-
    // issue here.
    window.__nativeAppSwitcher = () => sim && sim.pressButton('app-switcher');
    window.__nativeScreenshot = () => downloadSnapshot();
    window.__nativeClose = () => {
      // Shutting the window from inside a popup-style URL: try
      // window.close (only works for script-opened tabs) then fall
      // back to navigating to the list.
      try { window.close(); } catch (_) { /* ignore */ }
      if (!window.closed) location.href = '/simulators';
    };
    window.__nativeSetFormat = (next) => {
      if (next !== 'avcc' && next !== 'mjpeg') return;
      const current = localStorage.getItem('asc.simFormat') || pickFormat();
      if (current === next && session) return;
      localStorage.setItem('asc.simFormat', next);
      startSession(next);
    };
    window.__nativeToggleTheme = () => {
      setTheme(currentTheme() === 'light' ? 'dark' : 'light');
    };
    window.__nativeToggleLogs = () => toggleLogs();
    window.__nativeToggleCamera = () => toggleCamera();
    window.__nativeToggleStatusBar = () => toggleStatusBar();
    window.__nativeToggleAx = () => {
      if (!axInspector) return;
      if (axInspector.isEnabled()) axInspector.disable();
      else axInspector.enable();
    };
    // Sidebar-view jump — bounce out of focus mode and into the
    // inline `startStream` layout on `/simulators`. The hash is
    // the cue sim-stream.js reads on load to auto-open the same
    // device's stream view without an extra click.
    window.__nativeOpenSidebarView = () => {
      location.href = '/simulators#stream=' + encodeURIComponent(udid);
    };

    // Orientation cycle — one click advances 90° CW. Cycle length
    // varies by device class: 3 on iPhone (skips upside-down,
    // which iPhone UIKit ignores), 4 on iPad. POSTs the new value
    // through the `/simulators/<udid>/orientation?value=...` route;
    // server delegates to `simulator.orientation().set(...)`, which
    // fires a GSEvent over PurpleWorkspacePort.
    window.__nativeRotate = () => {
      const cycle = orientationCycle();
      orientationIndex = (orientationIndex + 1) % cycle.length;
      const value = cycle[orientationIndex];
      // Mirror the rotation in the UI immediately. The CSS
      // transform on `#nativeDeviceFrame > div` rotates the bezel
      // + canvas as one unit, while the input + overlay wrappers
      // remap coords back to portrait so taps still land on the
      // iOS element under the cursor.
      applyOrientation(value);
      const url = '/simulators/' + encodeURIComponent(udid)
          + '/orientation?value=' + encodeURIComponent(value);
      fetch(url, { method: 'POST' }).catch(() => { /* best-effort */ });
    };
  }

  // Surface a selected AX node in the floating `#nativeAxHost`
  // panel. Wraps the inspector's static selection renderer with a
  // header (title + close) so the panel can be dismissed without
  // disabling the inspector itself.
  function renderAxPanel(panel, node) {
    if (!panel) return;
    if (!node) {
      panel.removeAttribute('data-open');
      panel.innerHTML = '';
      return;
    }
    panel.setAttribute('data-open', 'true');
    panel.innerHTML =
        '<div class="ax-host-head">' +
        '<span>Element</span>' +
        '<button class="ax-host-close" data-role="ax-close" aria-label="Dismiss">×</button>' +
        '</div>' +
        '<div data-role="ax-body"></div>';
    panel.querySelector('[data-role="ax-close"]').addEventListener('click', () => {
      panel.removeAttribute('data-open');
      panel.innerHTML = '';
    });
    window.AXInspector.renderSelectionInto(
        panel.querySelector('[data-role="ax-body"]'),
        node,
        {
          send: (payload) => session && session.send(payload),
          getDeviceSize: () => ({ w: sim.screen.size.width, h: sim.screen.size.height }),
        }
    );
  }

  // Log sheet: lazy-mount on first open, leave the LogPanel attached
  // across subsequent toggles so a "close → reopen" doesn't drop the
  // backlog. Only `unmount` on page unload (or explicit close button
  // — same code path). The toolbar button toggles the
  // `[data-logs="open"]` attribute on `#simNativeView`; CSS handles
  // the slide-up animation and visibility.
  function toggleLogs() {
    const view = document.getElementById('simNativeView');
    const host = document.getElementById('nativeLogsHost');
    const btn  = document.getElementById('nativeLogsToggle');
    const open = view && view.getAttribute('data-logs') === 'open';
    if (!view || !host) return;
    if (open) {
      view.removeAttribute('data-logs');
      if (btn) btn.classList.remove('active');
    } else {
      view.setAttribute('data-logs', 'open');
      if (btn) btn.classList.add('active');
      if (!logPanel && window.LogPanel && udid) {
        host.innerHTML = '';
        logPanel = new window.LogPanel(host, { udid, level: 'info' });
      }
    }
  }

  // Camera sheet — same lazy-mount pattern as logs. The CameraPanel
  // owns its WS (/simulators/<udid>/camera); closing the sheet leaves
  // the panel mounted so reopening doesn't drop the streaming state
  // or device selection. The toolbar button's `.streaming` class
  // tracks the panel's reported phase so the user sees "camera on"
  // at a glance even when the sheet is closed.
  function toggleCamera() {
    const view = document.getElementById('simNativeView');
    const host = document.getElementById('nativeCameraHost');
    const btn  = document.getElementById('nativeCameraToggle');
    const open = view && view.getAttribute('data-camera') === 'open';
    if (!view || !host) return;
    if (open) {
      view.removeAttribute('data-camera');
      if (btn) btn.classList.remove('active');
    } else {
      view.setAttribute('data-camera', 'open');
      if (btn) btn.classList.add('active');
      if (!cameraPanel && window.CameraPanel && udid) {
        host.innerHTML = '';
        cameraPanel = new window.CameraPanel();
        cameraPanel.onPhaseChange = (phase) => {
          const indicator = document.getElementById('nativeCameraToggle');
          if (indicator) indicator.classList.toggle('streaming', phase === 'streaming');
        };
        cameraPanel.attach(host, udid);
      }
    }
  }

  // Status-bar card — same lazy-mount pattern as the camera sheet.
  // StatusBarPanel posts `simctl status_bar` overrides; closing the
  // card leaves it mounted so reopening keeps the control state. The
  // toolbar button's `.active` class tracks open/closed.
  function toggleStatusBar() {
    const view = document.getElementById('simNativeView');
    const host = document.getElementById('nativeStatusBarHost');
    const btn  = document.getElementById('nativeStatusBarToggle');
    const open = view && view.getAttribute('data-statusbar') === 'open';
    if (!view || !host) return;
    if (open) {
      view.removeAttribute('data-statusbar');
      if (btn) btn.classList.remove('active');
    } else {
      view.setAttribute('data-statusbar', 'open');
      if (btn) btn.classList.add('active');
      if (!statusBarPanel && window.StatusBarPanel && udid) {
        host.innerHTML = '';
        statusBarPanel = new window.StatusBarPanel();
        statusBarPanel.attach(host, udid);
      }
    }
  }

  function wireUnload() {
    window.addEventListener('beforeunload', () => {
      try { if (session) session.stop(); } catch (_) { /* ignore */ }
      try { if (sim) sim.detach(); } catch (_) { /* ignore */ }
      try { if (axInspector) axInspector.detach(); } catch (_) { /* ignore */ }
      try { if (cameraPanel) cameraPanel.detach(); } catch (_) { /* ignore */ }
      try { if (statusBarPanel) statusBarPanel.detach(); } catch (_) { /* ignore */ }
    });
  }

  // Take a snapshot from the live canvas and trigger a download. We
  // skip CaptureGallery here — the focus chrome has nowhere to put a
  // thumbnail strip, and the user just wants the file.
  function downloadSnapshot() {
    if (!sim || !sim.canvas) return;
    const w = lastPaintedSize.w || sim.canvas.width;
    const h = lastPaintedSize.h || sim.canvas.height;
    if (!w || !h) return;
    sim.canvas.toBlob((blob) => {
      if (!blob) return;
      const stamp = new Date().toISOString().replace(/[:.]/g, '-');
      const safe = (deviceName || 'simulator').replace(/[^A-Za-z0-9._-]/g, '_');
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = `${safe}-${stamp}.png`;
      document.body.appendChild(a);
      a.click();
      requestAnimationFrame(() => {
        URL.revokeObjectURL(a.href);
        a.remove();
      });
    }, 'image/png');
  }

  console.log('[Baguette] sim-native.js active for', udid);
})();
