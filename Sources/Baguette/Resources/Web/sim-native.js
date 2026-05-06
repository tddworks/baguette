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
  let frame = null;
  let surface = null;
  let simInput = null;
  let mouseSource = null;
  let pinchOverlay = null;
  let keyboardCapture = null;
  let logPanel = null;
  let lastPaintedSize = { w: 0, h: 0 };
  let layout = null;
  let deviceName = '';

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
    //    chrome.json gives us the bezel; /simulators.json gives us
    //    the human-readable identity that sits above it.
    const meta = await fetchDeviceMeta(udid);
    deviceName = meta.name;
    const nameEl = document.getElementById('nativeDeviceName');
    const osEl = document.getElementById('nativeDeviceOS');
    if (nameEl) nameEl.textContent = meta.name;
    if (osEl)   osEl.textContent   = meta.runtime;
    document.title = `${meta.name} — Baguette`;

    // 3. Layout drives bezel + screen rect + corner radius. Same
    //    endpoint sim-stream.js uses.
    layout = await fetch(`/simulators/${encodeURIComponent(udid)}/chrome.json`)
      .then((r) => (r.ok ? r.json() : null))
      .catch(() => null);

    // 4. Mount frame. Actionable mode is opt-in (toolbar toggle,
    //    persisted to localStorage). When on, `bezel.png?buttons=
    //    false` is fetched and BezelButtons overlays each hardware
    //    button with hover/click animations that fire SimInput.
    frame = new window.DeviceFrame({
      udid, layout,
      actionable: actionableEnabled(),
      onPress: (name, duration) => simInput && simInput.button(name, duration),
    });
    surface = frame.mount(document.getElementById('nativeDeviceFrame'));

    // 5. Open stream + wire input.
    startSession(pickFormat());

    wireKeyboard();
    wireActions();
    wireUnload();
    applyStoredTheme();
    reflectActionable();
  }

  // Actionable-bezel toggle. Off by default — the bezel renders
  // as today's flat composite. On, the device-frame swaps to
  // `bezel.png?buttons=false` and BezelButtons overlays each
  // hardware button with hover/click animations.
  const ACTIONABLE_KEY = 'baguette.actionableBezel';
  function actionableEnabled() {
    return localStorage.getItem(ACTIONABLE_KEY) === '1';
  }
  function setActionable(on) {
    if (on) localStorage.setItem(ACTIONABLE_KEY, '1');
    else    localStorage.removeItem(ACTIONABLE_KEY);
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
    session = new window.StreamSession({
      udid, format, version: 'v2',
      canvas: surface.canvas,
      onSize: (w, h) => { lastPaintedSize = { w, h }; },
      onFps:  (fps) => {
        const el = document.getElementById('nativeStatus');
        if (el) el.textContent = fps + ' fps';
      },
      onLog: (msg) => console.log('[native]', msg),
    });
    session.start();
    reflectFormat(format);
    wireInput(udid, frame.screenSize());
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

  function wireInput(targetUdid, screenSize) {
    // Detach any prior wiring — startSession() can be called multiple
    // times when the user swaps formats, and a fresh transport must
    // be bound to the new session. Without the detach the old
    // overlay handlers stack up and pinch dots leak.
    if (mouseSource) { try { mouseSource.detach(); } catch (_) {} mouseSource = null; }
    if (pinchOverlay) { try { pinchOverlay.clear(); } catch (_) {} pinchOverlay = null; }

    const log = (msg) => console.log('[native]', msg);
    simInput = new window.SimInput({
      udid: targetUdid,
      log,
      // Shared translator from sim-input-bridge.js — same dialect
      // adapter sim-stream.js and farm-tile.js use.
      transport: window.SimInputBridge.makeTransport(session, log),
    });
    simInput.setScreenSize(screenSize.w, screenSize.h);
    pinchOverlay = new window.PinchOverlay(surface.screenArea);
    mouseSource = new window.MouseGestureSource({
      el: surface.screenArea,
      input: simInput,
      overlay: pinchOverlay,
      log,
    });
    mouseSource.attach();
  }

  // Wire host-keyboard → simulator. Focus-gated: while the screen
  // area has focus, every supported keystroke is forwarded as a wire
  // `key` event (W3C `event.code` + modifier flags); when focus is
  // elsewhere (toolbar, header, etc.) the host browser keeps its
  // shortcuts. `mousedown` on the screen takes focus so the gate
  // opens automatically when the user starts interacting with iOS.
  function wireKeyboard() {
    const el = surface.screenArea;
    el.addEventListener('mousedown', () => el.focus());
    keyboardCapture = new window.KeyboardCapture({ target: el, simInput: () => simInput });
    keyboardCapture.start();
  }

  function wireActions() {
    window.__nativeHome = () => simInput && simInput.button('home');
    window.__nativeLock = () => simInput && simInput.button('lock');
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
    window.__nativeToggleActionable = () => {
      const next = !actionableEnabled();
      setActionable(next);
      reflectActionable();
      remountFrame();
    };
    window.__nativeToggleLogs = () => toggleLogs();
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

  // Re-mount the device frame after the actionable toggle flips. Tear
  // down current input wiring + bezel buttons, rebuild the frame in
  // the new mode, and re-bind a fresh SimInput chain over the new
  // surface. The live stream stays open — the canvas is the same
  // element, only the bezel image and overlays change.
  function remountFrame() {
    if (!frame) return;
    if (mouseSource) { try { mouseSource.detach(); } catch (_) {} mouseSource = null; }
    if (pinchOverlay) { try { pinchOverlay.clear(); } catch (_) {} pinchOverlay = null; }
    if (keyboardCapture) { try { keyboardCapture.stop(); } catch (_) {} keyboardCapture = null; }
    if (surface && surface.bezelButtons) {
      try { surface.bezelButtons.unmount(); } catch (_) { /* ignore */ }
    }
    frame = new window.DeviceFrame({
      udid, layout,
      actionable: actionableEnabled(),
      onPress: (name, duration) => simInput && simInput.button(name, duration),
    });
    surface = frame.mount(document.getElementById('nativeDeviceFrame'));
    // StreamSession captures the canvas at construction; the
    // remount produced a fresh canvas so we have to reopen the
    // session against it. Reuse the format the user already chose.
    startSession(pickFormat());
    wireKeyboard();
  }

  function reflectActionable() {
    const btn = document.getElementById('nativeActionableToggle');
    if (btn) btn.classList.toggle('active', actionableEnabled());
  }

  function wireUnload() {
    window.addEventListener('beforeunload', () => {
      try { if (session) session.stop(); } catch (_) { /* ignore */ }
      try { if (mouseSource) mouseSource.detach(); } catch (_) { /* ignore */ }
      try { if (keyboardCapture) keyboardCapture.stop(); } catch (_) { /* ignore */ }
    });
  }

  // Take a snapshot from the live canvas and trigger a download. We
  // skip CaptureGallery here — the focus chrome has nowhere to put a
  // thumbnail strip, and the user just wants the file.
  function downloadSnapshot() {
    if (!surface || !surface.canvas) return;
    const w = lastPaintedSize.w || surface.canvas.width;
    const h = lastPaintedSize.h || surface.canvas.height;
    if (!w || !h) return;
    surface.canvas.toBlob((blob) => {
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
