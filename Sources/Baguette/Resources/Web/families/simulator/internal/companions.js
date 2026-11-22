// A simulator's companion screens: the CarPlay display and the paired
// watch, each in a pane of its own beside the phone, each with its own
// stream and input, opened from the screens rail. The Simulator family's
// `companions` role (families/simulator/simulator.js). What it needs of the
// page is its port: { udid, socketFormat(), refreshToolbarScroll(), rightRails() }.

import { ScreensRail } from './screens-rail.js';
import { StreamSession } from '../../../stream/stream-session.js';
import { Transport } from '../../../baguette/transport.js';
import { Screen } from '../../../baguette/parts/screen.js';
import { CarPlayFrameRegistry } from '../../../baguette/carplay/frame-registry.js';
import { CarPlayFrame } from '../../../baguette/carplay/carplay-frame.js';

export function companionScreens(page) {
  let carplaySession = null;
  let carplayScreen = null;
  let carplayFrame = null;  // Baguette._CarPlayFrame mount (brand chrome)
  // Bumped by every CarPlay start and by closing the pane. Starting a
  // session awaits a brand-chrome load that takes as long as a fetch, and
  // a format swap or a pane close lands during that await. Without a
  // generation to check on the far side, the slower start would mount
  // onto a canvas the newer one had already replaced and overwrite
  // `carplaySession` without stopping it — leaving a live socket nothing
  // tracks, streaming video at a detached canvas until the page unloads.
  let carplayGeneration = 0;
  let watchSession = null;  // paired Apple Watch — its own device, its own stream
  let watchScreen = null;
  let screensRail = null;   // ScreensRail — which companion screens are shown
  const openCompanions = new Set();
  function mountScreensRail() {
    screensRail = new ScreensRail({
      udid: page.udid,
      mount: page.rightRails(),
      onOpen: (entry) => openCompanion(entry),
      onClose: (entry) => closeCompanion(entry),
      log: (msg) => console.log('[screens]', msg),
    });
    screensRail.load();
  }

  function openCompanion(entry) {
    if (entry.id === 'external') {
      showCompanionColumn('nativeCarPlayColumn', true);
      openCompanions.add('external');
      // CarPlay follows the phone's format. It was pinned to MJPEG
      // because a mostly-static CarPlay plane was thought to starve
      // H.264 of the IDR cadence the guest never produces — but
      // `AVCCStream` re-encodes its last surface on an idle pump for
      // exactly that reason, so the plane stays live. Measured on an
      // idle CarPlay screen: avcc delivers ~59 fps, while MJPEG (which
      // has no idle pump) delivers one frame per twelve seconds.
      void startCarPlaySession();
    } else if (entry.id === 'watch') {
      const label = document.getElementById('nativeWatchLabel');
      if (label) label.textContent = entry.label;
      showCompanionColumn('nativeWatchColumn', true);
      openCompanions.add('watch');
      void startWatchSession(entry.udid);
    }
    reflectCompanions();
  }

  function closeCompanion(entry) {
    openCompanions.delete(entry.id);
    if (entry.id === 'external') {
      stopCarPlaySession();
      showCompanionColumn('nativeCarPlayColumn', false);
    } else if (entry.id === 'watch') {
      stopWatchSession();
      showCompanionColumn('nativeWatchColumn', false);
    }
    reflectCompanions();
  }

  function showCompanionColumn(id, visible) {
    const column = document.getElementById(id);
    if (column) column.hidden = !visible;
  }

  /// The open panes, on the root, as a space-separated list — the size
  /// budget in page/device-page.html reads it to decide how much of the
  /// window the device may take when something is beside it.
  function reflectCompanions() {
    const view = document.getElementById('simNativeView');
    if (!view) return;
    if (!openCompanions.size) view.removeAttribute('data-companions');
    else view.setAttribute('data-companions', [...openCompanions].sort().join(' '));
    // The toolbar's width budget just changed with it; let the new
    // layout settle before asking the strip whether it now overflows.
    requestAnimationFrame(() => page.refreshToolbarScroll());
  }

  // CarPlay pane: own StreamSession (?display=carplay) + Screen gestures
  // that send only on that socket. Brand chrome mounts via
  // `_CarPlayFrame` (registry under /carplay-frames/); plain rect is
  // the fallback when the registry/scripts are unavailable.
  const CARPLAY_DEFAULT_SIZE = { width: 800, height: 450 };

  function resolveCarPlayBrand() {
    const q = new URLSearchParams(location.search).get('frame');
    if (q) return q;
    const el = document.getElementById('nativeCarPlayFrame');
    return (el && el.dataset.frameBrand) || 'plain';
  }

  async function ensureCarPlayFrameMounted(generation) {
    const anchor = document.getElementById('nativeCarPlayFrame');
    if (!anchor) return null;
    // Prefer plain rect until brand chrome is proven with live frames —
    // async Cupra mount was racing the stream onto a detached canvas.
    const brand = resolveCarPlayBrand();
    if (brand === 'plain') {
      const canvas = document.getElementById('nativeCarPlayCanvas');
      return canvas ? { screenArea: anchor, canvas } : null;
    }
    if (carplayFrame && carplayFrame.ports().canvas) {
      return carplayFrame.ports();
    }
    try {
      const packed = await CarPlayFrameRegistry.load(resolveCarPlayBrand());
      // A newer start (or a close) came while the chrome loaded: its frame stays.
      if (generation !== carplayGeneration) return null;
      if (carplayFrame) carplayFrame.detach();
      carplayFrame = new CarPlayFrame(packed.definition, {
        assetBaseUrl: packed.assetBaseUrl,
      });
      return carplayFrame.mount(anchor);
    } catch (err) {
      console.warn('[native:carplay] frame mount failed; using plain rect', err);
      const canvas = document.getElementById('nativeCarPlayCanvas');
      return canvas ? { screenArea: anchor, canvas } : null;
    }
  }

  async function startCarPlaySession(format = page.socketFormat()) {
    const generation = ++carplayGeneration;
    if (carplaySession) { try { carplaySession.stop(); } catch (_) {} carplaySession = null; }

    const ports = await ensureCarPlayFrameMounted(generation);
    // A newer start (or a pane close) overtook us while the chrome
    // loaded; it owns the canvas and the session now, so stand down.
    if (generation !== carplayGeneration) return;
    if (!ports || !ports.canvas || !ports.screenArea) return;

    // Remount replaces the canvas; drop the old Screen so gestures
    // rebind to the cutout.
    if (carplayScreen) {
      try { carplayScreen.detach(); } catch (_) { /* ignore */ }
      carplayScreen = null;
    }
    // Gestures here restarted the guest for a long time. The cause was
    // never the pane; it was that every touch carried a HID target no
    // service had registered, and `SimHIDVirtualServiceManager` answers
    // that by throwing — which takes backboardd and SpringBoard with it.
    //
    // Two things were wrong, and the guest named both as it died:
    //   - the CarPlay service was never created (warmServices built the
    //     pointer and mouse ones and stopped there), and
    //   - the target was computed by `IndigoHIDTargetForScreen`, which
    //     returns `0x40000000 | screenId` — plausible, and registered by
    //     nothing. CarPlay's target is a fixed `0x40000001`.
    //
    // Both are fixed server-side, and `warmServices` now fails closed:
    // if the service cannot be created there is no client, so gestures
    // are dropped rather than aimed at a target that kills the guest.
    ensureCarPlayInput(ports.screenArea, ports.canvas);

    clearCompanionFault('nativeCarPlayColumn');
    carplaySession = new StreamSession({
      udid: page.udid, format, version: 'v2',
      display: 'carplay',
      canvas: ports.canvas,
      onSize: (w, h) => {
        clearCompanionFault('nativeCarPlayColumn');
        if (carplayScreen) {
          carplayScreen.def.rect.width = w;
          carplayScreen.def.rect.height = h;
          carplayScreen.transport.setScreenSize(w, h);
        }
      },
      onText: (env) => showCompanionFault('nativeCarPlayColumn', 'external', env),
      onLog: (msg) => console.log('[native:carplay]', msg),
    });
    carplaySession.start();
  }

  // --- When a companion stream can't bind ------------------------------
  //
  // The server already says why: it writes `{"ok":false,"error":…}` on
  // the socket and closes. That answer used to go to `console.log` and
  // nowhere else, so the pane sat there as an unexplained black
  // rectangle — the single most confusing thing about the CarPlay pane.
  // `noMatchingFramebuffer(carPlay)` means the display is registered but has no
  // framebuffer, which is a thing the user can actually fix, so it
  // belongs on the pane next to the instructions for fixing it.

  function showCompanionFault(columnId, entryId, env) {
    if (!env || env.ok !== false || !env.error) return false;
    const column = document.getElementById(columnId);
    if (!column) return true;
    clearCompanionFault(columnId);

    const entry = screensRail && screensRail.entry(entryId);
    const note = document.createElement('div');
    note.className = 'companion-fault';

    const title = document.createElement('div');
    title.className = 'companion-fault-title';
    title.textContent = /noMatchingFramebuffer/.test(env.error)
      ? 'Nothing is rendering to this screen'
      : 'This screen could not be opened';
    note.appendChild(title);

    const steps = document.createElement('ol');
    steps.className = 'companion-fault-steps';
    for (const step of (entry && entry.instructions) || []) {
      const item = document.createElement('li');
      item.textContent = step;
      steps.appendChild(item);
    }
    note.appendChild(steps);

    // The server's own words, kept verbatim and last — it is the thing
    // to search for when the steps above don't help.
    const raw = document.createElement('code');
    raw.className = 'companion-fault-raw';
    raw.textContent = env.error;
    note.appendChild(raw);

    column.appendChild(note);
    return true;
  }

  function clearCompanionFault(columnId) {
    const column = document.getElementById(columnId);
    if (!column) return;
    const existing = column.querySelector('.companion-fault');
    if (existing) existing.remove();
  }

  function stopCarPlaySession() {
    // Closing the pane retires any start still waiting on its chrome.
    carplayGeneration += 1;
    if (carplaySession) { try { carplaySession.stop(); } catch (_) {} carplaySession = null; }
    if (carplayScreen)  { try { carplayScreen.detach(); } catch (_) {} carplayScreen = null; }
  }

  function ensureCarPlayInput(screenArea, canvas) {
    if (carplayScreen) return;
    const transport = new Transport({
      send: (payload) => carplaySession && carplaySession.send(payload),
      log: (msg) => console.log('[native:carplay]', msg),
    });
    carplayScreen = new Screen(
      { rect: { width: CARPLAY_DEFAULT_SIZE.width, height: CARPLAY_DEFAULT_SIZE.height } },
      transport,
      { getOrientation: () => 'landscape-right', log: (msg) => console.log('[native:carplay]', msg) }
    );
    carplayScreen.bindDOM({ screenArea, canvas });
  }

  // Watch pane: a paired Apple Watch is a device of its own, not a
  // second plane of this one — so it streams on its OWN udid down the
  // ordinary phone-display route, and its gestures go down that socket.
  // Nothing here is CarPlay-shaped; the only thing the two panes share
  // is that the rail decides whether they exist.
  const WATCH_DEFAULT_SIZE = { width: 410, height: 502 };
  let watchUdid = null;

  async function startWatchSession(nextUdid) {
    if (nextUdid) watchUdid = nextUdid;
    if (!watchUdid) return;
    stopWatchSession();

    const screenArea = document.getElementById('nativeWatchFrame');
    const canvas = document.getElementById('nativeWatchCanvas');
    if (!screenArea || !canvas) return;

    ensureWatchInput(screenArea, canvas);
    clearCompanionFault('nativeWatchColumn');
    watchSession = new StreamSession({
      udid: watchUdid, format: page.socketFormat(), version: 'v2',
      display: 'phone',
      canvas,
      onSize: (w, h) => {
        // Take the frame's shape from the watch itself. The CSS starts
        // at a Series-sized 41:50 so the empty pane isn't shapeless, but
        // every model differs — a 46mm is 416×496, an Ultra and a 42mm
        // are neither — and a guessed ratio just letterboxes the face
        // inside its own bezel.
        if (w && h) screenArea.style.aspectRatio = w + ' / ' + h;
        clearCompanionFault('nativeWatchColumn');
        if (!watchScreen) return;
        watchScreen.def.rect.width = w;
        watchScreen.def.rect.height = h;
        watchScreen.transport.setScreenSize(w, h);
      },
      onText: (env) => showCompanionFault('nativeWatchColumn', 'watch', env),
      onLog: (msg) => console.log('[native:watch]', msg),
    });
    watchSession.start();
  }

  function stopWatchSession() {
    if (watchSession) { try { watchSession.stop(); } catch (_) {} watchSession = null; }
    if (watchScreen)  { try { watchScreen.detach(); } catch (_) {} watchScreen = null; }
    // Back to the stylesheet's placeholder shape, so reopening onto a
    // different watch doesn't briefly wear the last one's proportions.
    const frame = document.getElementById('nativeWatchFrame');
    if (frame) frame.style.aspectRatio = '';
  }

  function ensureWatchInput(screenArea, canvas) {
    if (watchScreen) return;
    const transport = new Transport({
      send: (payload) => watchSession && watchSession.send(payload),
      log: (msg) => console.log('[native:watch]', msg),
    });
    watchScreen = new Screen(
      { rect: { width: WATCH_DEFAULT_SIZE.width, height: WATCH_DEFAULT_SIZE.height } },
      transport,
      { getOrientation: () => 'portrait', log: (msg) => console.log('[native:watch]', msg) }
    );
    watchScreen.bindDOM({ screenArea, canvas });
  }

  /// The main stream restarted: its sockets went with it, so the companion
  /// panes the user has open start again, in the page's `format`.
  function resume(format) {
    if (openCompanions.has('external')) void startCarPlaySession(format);
    if (openCompanions.has('watch')) void startWatchSession();
  }

  /// A watch hardware button, down the watch's own socket — it has to reach
  /// the watch's HID, not the phone beside it; nothing when its pane is shut.
  function pressWatch(name) {
    if (watchSession) watchSession.send({ type: 'button', button: name });
  }

  /// The page is going: every companion lets go.
  function detach() {
    // Retires a start still waiting on its chrome, and stops what's running.
    try { stopCarPlaySession(); } catch (_) { /* ignore */ }
    try { if (carplayFrame) carplayFrame.detach(); } catch (_) { /* ignore */ }
    carplayFrame = null;
    try { if (watchSession) watchSession.stop(); } catch (_) { /* ignore */ }
    try { if (watchScreen) watchScreen.detach(); } catch (_) { /* ignore */ }
    try { if (screensRail) screensRail.detach(); } catch (_) { /* ignore */ }
  }

  return { mountScreensRail, resume, pressWatch, detach };
}

