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
    // Reset whatever sim.html landed with (style block is fine; the
    // <body> background gets overridden by the focus-mode <style>).
    document.body.innerHTML = '';
    document.body.style.cssText = 'margin:0;padding:0;background:#1a1a1f;overflow:hidden';

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

    // 4. Mount frame.
    frame = new window.DeviceFrame({ udid, layout });
    surface = frame.mount(document.getElementById('nativeDeviceFrame'));

    // 5. Open stream + wire input.
    const format = pickFormat();
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

    wireInput(udid, frame.screenSize());
    wireKeyboard();
    wireActions();
    wireUnload();
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
    simInput = new window.SimInput({
      udid: targetUdid,
      log: (msg) => console.log('[native]', msg),
      // Same SimInput → Baguette wire translation as sim-stream.js.
      // Kept inline so the focus mode has zero coupling to the
      // sidebar orchestrator (which is its own private IIFE).
      transport: (payload) => {
        const wire = toBaguetteWire(payload);
        if (wire && session) session.send(wire);
      },
    });
    simInput.setScreenSize(screenSize.w, screenSize.h);
    pinchOverlay = new window.PinchOverlay(surface.screenArea);
    mouseSource = new window.MouseGestureSource({
      el: surface.screenArea,
      input: simInput,
      overlay: pinchOverlay,
      log: (msg) => console.log('[native]', msg),
    });
    mouseSource.attach();
  }

  function wireKeyboard() {
    const KEY_HID = {
      Backspace: 42, Enter: 40, Tab: 43, Escape: 41,
      ArrowUp: 82, ArrowDown: 81, ArrowLeft: 80, ArrowRight: 79,
    };
    const el = surface.screenArea;
    el.addEventListener('mousedown', () => el.focus());
    el.addEventListener('keydown', (e) => {
      if (e.metaKey || e.ctrlKey) return;
      const hid = KEY_HID[e.key];
      if (hid !== undefined) {
        e.preventDefault();
        simInput.key(hid);
        return;
      }
      if (e.key.length === 1 && !e.altKey) {
        e.preventDefault();
        simInput.type(e.key);
      }
    });
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
  }

  function wireUnload() {
    window.addEventListener('beforeunload', () => {
      try { if (session) session.stop(); } catch (_) { /* ignore */ }
      try { if (mouseSource) mouseSource.detach(); } catch (_) { /* ignore */ }
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

  // SimInput → Baguette wire-format translator (mirrors sim-stream.js).
  function toBaguetteWire(p) {
    const w = p.width, h = p.height;
    const base = { width: w, height: h };
    const px = (x) => x * w;
    const py = (y) => y * h;
    switch (p.kind) {
      case 'tap':
        return { type: 'tap', x: px(p.x), y: py(p.y),
                 duration: p.duration != null ? p.duration : 0.05, ...base };
      case 'swipe':
        return {
          type: 'swipe',
          startX: px(p.x1), startY: py(p.y1),
          endX:   px(p.x2), endY:   py(p.y2),
          duration: p.duration != null ? p.duration : 0.25,
          ...base,
        };
      case 'touchDown':
      case 'touchMove':
      case 'touchUp':
        return phasedTouchWire(p, base, px, py);
      case 'scroll':
        return { type: 'scroll', deltaX: p.deltaX, deltaY: p.deltaY };
      case 'button':
        return { type: 'button', button: p.button };
      case 'key':
      case 'type':
        // Not on Baguette's host-HID path yet — drop quietly.
        return null;
      default:
        return null;
    }
  }

  function phasedTouchWire(p, base, px, py) {
    const phase = p.kind.replace('touch', '').toLowerCase();
    const fingers = p.fingers || [];
    if (fingers.length === 1) {
      return {
        type: `touch1-${phase}`,
        x: px(fingers[0].x), y: py(fingers[0].y),
        ...base,
      };
    }
    if (fingers.length === 2) {
      return {
        type: `touch2-${phase}`,
        x1: px(fingers[0].x), y1: py(fingers[0].y),
        x2: px(fingers[1].x), y2: py(fingers[1].y),
        ...base,
      };
    }
    return null;
  }

  console.log('[Baguette] sim-native.js active for', udid);
})();
