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
  let sim = null;           // Baguette SDK Simulator
  let logPanel = null;
  let axInspector = null;
  let pluginPanels = null;   // PluginPanels — manifest-declared plugin UI
  let cameraPanel = null;   // CameraPanel — Mac webcam → /tmp/SimCam.bgra
  let statusBarPanel = null; // StatusBarPanel — simctl status_bar overrides
  let locationPanel = null;  // LocationPanel — simctl location map picker
  let networkPanel = null;   // NetworkPanel — latency / bandwidth / loss / offline
  let networkArmedTimer = null; // keeps the toolbar's armed dot honest while the card is shut
  let render3DPanel = null;  // Sim3DPanel — live SceneKit stream + inspector
  let lastPaintedSize = { w: 0, h: 0 };
  let deviceName = '';
  let powerCard = null;      // boot affordance shown on an unbooted device's screen
  let bootPollTimer = null;  // /simulators.json poll while a boot is in flight
  let firstFrameTimer = null; // fallback so the card can't outlive a live stream

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
    //
    //    `use` rejects when `definition.json` 404s — the udid isn't in
    //    the device set (deep link to a deleted device, typo'd UDID) or
    //    the model has no DeviceKit chrome. Without the catch the whole
    //    bootstrap unwinds and the tab sits blank; the power card says
    //    so instead.
    try {
      sim = await window.Baguette.use({
        host: location.origin,
        udid,
        send: (payload) => {
          const out = currentOrientation === 'portrait'
            ? payload
            : remapEnvelopeToPortrait(payload);
          const view = document.getElementById('simNativeView');
          if (view && view.getAttribute('data-render3d') === 'open' &&
              render3DPanel && render3DPanel.send(out)) return;
          if (session) session.send(out);
        },
        getOrientation: () => currentOrientation,
        log: (msg) => console.log('[native]', msg),
      });
      sim.mount(document.getElementById('nativeDeviceFrame'));
    } catch (e) {
      console.warn('[native] no device definition:', (e && e.message) || e);
      sim = null;
    }

    // 4. Companion-screens rail. Mounted before the stream opens, and
    //    regardless of whether the device is booted: "what other screens
    //    could I be looking at" is a question worth answering on a
    //    device that isn't running yet, and the rail's answer for a
    //    screen that isn't there is instructions rather than a pane.
    //    Also mounts first so it sits above the plugins rail in the
    //    shared right-edge stack.
    mountScreensRail();

    // 5. Open stream — but only if there's a guest to stream. A
    //    shutdown device has no framebuffer, no HID, and no
    //    PurpleWorkspacePort; opening the socket would just paint
    //    black forever with no hint as to why. Show the power card on
    //    the device's own screen instead and start the stream once
    //    the user boots it (or once the boot already underway lands).
    if (sim && isBooted(meta.state)) {
      startSession(currentFormat());
    } else {
      showPowerCard(sim ? meta.state : '');
    }

    wireActions();
    wireToolbarScroll();
    wireUnload();
    applyStoredTheme();

    // Capture surface — the output-size chip and the Record button.
    // Deliberately not awaited: the size vocabulary is four small files
    // and nothing on the stream path needs them, so the device paints
    // while they arrive.
    void ensureCaptureModules().then(mountCaptureUI);

    // Drag-and-drop: drop an .ipa/.app to install, or an image/video to
    // add to Photos. Dumb sender — POSTs the bytes to `/files`; the
    // Swift side routes by extension. The drop zone + highlight are
    // scoped to the device frame so the overlay traces the phone, not
    // the whole page. See docs/features/file-upload.md.
    if (window.SimFileDrop) {
      window.__fileDrop =
          window.SimFileDrop.attach(document.getElementById('nativeDeviceFrame'), { udid });
    }

    // Reset iOS to portrait on page boot. Without this, a page
    // reload would leave our JS state at `currentOrientation =
    // 'portrait'` (rotation degrees 0) while iOS still holds
    // whatever orientation it was set to in a previous session
    // — the bezel renders un-rotated but the iOS framebuffer
    // shows UI from the stale orientation, which looks upside
    // down to the user.
    //
    // Only meaningful once the guest is up: an unbooted device has no
    // PurpleWorkspacePort to send the GSEvent to. `resetToPortrait`
    // runs again after a boot completes.
    if (isBooted(meta.state)) resetToPortrait();

    // Start watching for network conditioning immediately, before the card
    // has ever been opened. A throttle armed from the CLI in another
    // terminal is exactly the one someone forgets about, and this page is
    // where they will be looking when the app feels slow.
    watchNetworkArmed();
  }

  function resetToPortrait() {
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

  function live3DBackground() {
    const root = document.getElementById('simNativeView');
    const computed = root
        ? getComputedStyle(root).getPropertyValue('--nv-page-bg').trim()
        : '';
    if (/^#[0-9a-f]{6}$/i.test(computed)) return computed;
    return currentTheme() === 'light' ? '#f1f3f6' : '#1a1a1f';
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
    if (render3DPanel && root.getAttribute('data-render3d') === 'open') {
      render3DPanel.setBackground(live3DBackground());
    }
  }

  // Open (or reopen) a StreamSession on the existing surface for a
  // given wire format. Tearing down + restarting is the cheapest way
  // to swap formats — the WS protocol is per-connection and the
  // server's makeStream(...) is keyed at session open.
  function startSession(format) {
    // A recording samples the canvas this session paints into; a
    // restart (format swap, 3D close, device re-open) leaves it blank
    // for however long the new socket takes to land its first frame.
    if (session) cancelRecording('stream restarted');
    if (session) { try { session.stop(); } catch (_) {} session = null; }
    // Same text-frame router as sim-stream.js: hand JSON envelopes
    // to the inspector first, then claim paste_result; anything
    // nobody claims falls through to the decoder's error logger.
    const onStreamText = (env) => {
      if (axInspector && axInspector.handleEnvelope(env)) return true;
      if (env && env.type === 'paste_result') {
        if (!env.ok) console.warn('[native] paste failed:', env.error || 'unknown');
        return true;
      }
      if (env && env.type === 'copy_result') {
        console.log(env.ok
          ? '[native] copied sim pasteboard to host clipboard'
          : '[native] copy failed: ' + (env.error || 'unknown'));
        return true;
      }
      return false;
    };
    session = new window.StreamSession({
      udid, format, version: 'v2',
      display: 'phone',
      canvas: sim.canvas,
      onSize: (w, h) => {
        lastPaintedSize = { w, h };
        // First frame after a boot — the guest is genuinely up, so
        // drop the power card and hand the screen back to the stream.
        hidePowerCard();
      },
      onFps:  (fps) => {
        const el = document.getElementById('nativeStatus');
        if (el) el.textContent = fps + ' fps';
      },
      onLog: (msg) => console.log('[native]', msg),
      onText: onStreamText,
    });
    session.start();
    // Companion panes are the user's standing choice, not this
    // session's — but their sockets don't survive a phone-session
    // restart's teardown, so reopen whichever are showing.
    if (openCompanions.has('external')) void startCarPlaySession(format);
    if (openCompanions.has('watch')) void startWatchSession();
    reflectFormat(format);
    // Restore the cached orientation across format-swap remounts,
    // so reopening the session doesn't snap the device back to
    // portrait while the simulator is still landscape.
    if (currentOrientation !== 'portrait') applyOrientation(currentOrientation);
    mountAxInspector();
    // Once only — `startSession` re-runs on every format swap, and
    // re-mounting would append a second copy of every rail button.
    if (!pluginPanels) mountPlugins();
  }

  // --- Companion screens ---------------------------------------------
  //
  // The CarPlay pane and the paired-watch pane are opt-in, driven by the
  // rail on the right edge. They used to be neither: the CarPlay pane
  // mounted on every page load, and because `?display=carplay` asks the
  // host to *attach* a CarPlay display, simply opening a device's tab
  // reached into Simulator.app and turned one on. Now nothing is asked
  // for until the rail is told to show it, and the rail only offers a
  // screen the host reports as already there.

  function mountScreensRail() {
    if (!window.ScreensRail || !window.Baguette || !window.Baguette._CompanionScreens) return;
    screensRail = new window.ScreensRail({
      udid,
      mount: rightRails(),
      onOpen: (entry) => openCompanion(entry),
      onClose: (entry) => closeCompanion(entry),
      log: (msg) => console.log('[screens]', msg),
    });
    screensRail.load();
  }

  /// Both right-edge rails live in one stack so they can't overlap.
  /// Falls back to the view root if the template predates it.
  function rightRails() {
    return document.getElementById('nativeRightRails')
        || document.getElementById('simNativeView')
        || document.body;
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
  /// budget in sim-native.html reads it to decide how much of the
  /// window the device may take when something is beside it.
  function reflectCompanions() {
    const view = document.getElementById('simNativeView');
    if (!view) return;
    if (!openCompanions.size) view.removeAttribute('data-companions');
    else view.setAttribute('data-companions', [...openCompanions].sort().join(' '));
    // The toolbar's width budget just changed with it; let the new
    // layout settle before asking the strip whether it now overflows.
    requestAnimationFrame(() => refreshToolbarScroll());
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

  async function ensureCarPlayFrameMounted() {
    const anchor = document.getElementById('nativeCarPlayFrame');
    if (!anchor) return null;
    const B = window.Baguette;
    // Prefer plain rect until brand chrome is proven with live frames —
    // async Cupra mount was racing the stream onto a detached canvas.
    const brand = resolveCarPlayBrand();
    if (brand === 'plain' || !B || !B._CarPlayFrameRegistry || !B._CarPlayFrame) {
      const canvas = document.getElementById('nativeCarPlayCanvas');
      return canvas ? { screenArea: anchor, canvas } : null;
    }
    if (carplayFrame && carplayFrame.ports().canvas) {
      return carplayFrame.ports();
    }
    try {
      const packed = await B._CarPlayFrameRegistry.load(resolveCarPlayBrand());
      if (carplayFrame) carplayFrame.detach();
      carplayFrame = new B._CarPlayFrame(packed.definition, {
        assetBaseUrl: packed.assetBaseUrl,
      });
      return carplayFrame.mount(anchor);
    } catch (err) {
      console.warn('[native:carplay] frame mount failed; using plain rect', err);
      const canvas = document.getElementById('nativeCarPlayCanvas');
      return canvas ? { screenArea: anchor, canvas } : null;
    }
  }

  async function startCarPlaySession(format = currentFormat()) {
    const generation = ++carplayGeneration;
    if (carplaySession) { try { carplaySession.stop(); } catch (_) {} carplaySession = null; }
    if (!window.StreamSession) return;

    const ports = await ensureCarPlayFrameMounted();
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
    carplaySession = new window.StreamSession({
      udid, format, version: 'v2',
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
  // `noMatchingPort(carPlay)` means the display is registered but has no
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
    title.textContent = /noMatchingPort/.test(env.error)
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
    if (carplayScreen || !window.Baguette || !window.Baguette._Screen) return;
    const transport = new window.Baguette._Transport({
      send: (payload) => carplaySession && carplaySession.send(payload),
      log: (msg) => console.log('[native:carplay]', msg),
    });
    carplayScreen = new window.Baguette._Screen(
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
    if (!watchUdid || !window.StreamSession) return;
    stopWatchSession();

    const screenArea = document.getElementById('nativeWatchFrame');
    const canvas = document.getElementById('nativeWatchCanvas');
    if (!screenArea || !canvas) return;

    ensureWatchInput(screenArea, canvas);
    clearCompanionFault('nativeWatchColumn');
    watchSession = new window.StreamSession({
      udid: watchUdid, format: currentFormat(), version: 'v2',
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
    if (watchScreen || !window.Baguette || !window.Baguette._Screen) return;
    const transport = new window.Baguette._Transport({
      send: (payload) => watchSession && watchSession.send(payload),
      log: (msg) => console.log('[native:watch]', msg),
    });
    watchScreen = new window.Baguette._Screen(
      { rect: { width: WATCH_DEFAULT_SIZE.width, height: WATCH_DEFAULT_SIZE.height } },
      transport,
      { getOrientation: () => 'portrait', log: (msg) => console.log('[native:watch]', msg) }
    );
    watchScreen.bindDOM({ screenArea, canvas });
  }

  // --- Power card ----------------------------------------------------
  // A tab opened on a device that isn't running used to load a bezel
  // wrapped around a socket that would never carry a frame — no boot
  // control anywhere in focus mode, so the only way out was back to
  // the list. The card puts the boot control on the device's own
  // screen and drives the wait, then hands the screen to the stream.
  //
  // Three phases:
  //   off      — Boot button. The device is Shutdown (or shutting down).
  //   booting  — POST sent (or the device was already Booting when the
  //              tab opened); polling /simulators.json for "Booted".
  //   starting — CoreSimulator says Booted; the stream is open and
  //              we're waiting on the first composited frame.
  // `gone` is the degenerate case: the udid isn't in the device set at
  // all, so there is nothing to boot.

  const BOOT_POLL_MS = 1000;
  const BOOT_TIMEOUT_MS = 180000;   // cold boots on a busy Mac are slow
  const FIRST_FRAME_TIMEOUT_MS = 15000;
  const IDLE_POLL_MS = 4000;        // watch for a boot we didn't start

  function isBooted(state) {
    return String(state || '') === 'Booted';
  }

  function showPowerCard(state) {
    hidePowerCard();

    // Normally the card goes on the device's own glass. With no
    // definition there's no bezel to sit inside, so it stands alone in
    // the empty device slot and gets its own device-ish silhouette.
    const glass = sim && sim.screenArea;
    const host = glass || document.getElementById('nativeDeviceFrame');
    if (!host) return;

    powerCard = document.createElement('div');
    powerCard.className = glass ? 'power-card' : 'power-card power-card--bare';
    // The SDK's PointerInterpreter is attached to the same screenArea.
    // Without this, clicking Boot also dispatches a tap gesture at the
    // button's coords into a simulator that can't receive it.
    ['pointerdown', 'pointerup', 'pointermove', 'mousedown', 'mouseup', 'click']
        .forEach((evt) => powerCard.addEventListener(evt, (e) => e.stopPropagation()));
    host.appendChild(powerCard);

    if (!state) {
      renderPowerCard('gone');
    } else if (String(state) === 'Booting') {
      // Someone else already started it — join the wait rather than
      // POSTing a second boot.
      renderPowerCard('booting');
      waitForBoot();
    } else {
      renderPowerCard('off');
    }
  }

  function hidePowerCard() {
    if (!powerCard && !bootPollTimer && !firstFrameTimer) return;
    if (bootPollTimer)   { clearTimeout(bootPollTimer);   bootPollTimer = null; }
    if (firstFrameTimer) { clearTimeout(firstFrameTimer); firstFrameTimer = null; }
    if (powerCard && powerCard.parentNode) powerCard.parentNode.removeChild(powerCard);
    powerCard = null;
    const view = document.getElementById('simNativeView');
    if (view) view.removeAttribute('data-power');
  }

  const POWER_GLYPH =
      '<path d="M12 3.5v7.5"/>' +
      '<path d="M6.9 6.9a7.5 7.5 0 1 0 10.2 0"/>';
  const SPIN_GLYPH =
      '<circle cx="12" cy="12" r="8.6" stroke-opacity="0.22"/>' +
      '<path d="M20.6 12A8.6 8.6 0 0 0 12 3.4"/>';

  // Renders one phase into the existing card. `detail` overrides the
  // subtitle — used to surface a boot failure verbatim instead of a
  // generic "try again".
  function renderPowerCard(phase, detail) {
    if (!powerCard) return;
    // Whatever poll belonged to the previous phase is done with.
    if (bootPollTimer) { clearTimeout(bootPollTimer); bootPollTimer = null; }
    powerCard.setAttribute('data-phase', phase);
    // Presence of `data-power` on the root is what dims the toolbar;
    // the value carries the phase for anyone inspecting the DOM.
    const view = document.getElementById('simNativeView');
    if (view) view.setAttribute('data-power', phase);

    const copy = {
      off:      { title: 'Not booted',  sub: deviceName || 'This simulator', btn: 'Boot' },
      booting:  { title: 'Booting…',    sub: 'Waiting for CoreSimulator',    btn: null },
      starting: { title: 'Starting…',   sub: 'Waiting for the first frame',  btn: null },
      gone:     { title: 'Unavailable', sub: 'This simulator is no longer in the device set.', btn: null },
    }[phase] || {};

    const glyph = (phase === 'booting' || phase === 'starting') ? SPIN_GLYPH : POWER_GLYPH;
    powerCard.innerHTML =
        '<svg class="power-glyph" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
        'stroke-width="1.7" stroke-linecap="round" width="34" height="34" aria-hidden="true">' +
        glyph + '</svg>' +
        '<div class="power-title"></div>' +
        '<div class="power-sub"></div>' +
        (copy.btn ? '<button class="power-btn" type="button"></button>' : '');

    powerCard.querySelector('.power-title').textContent = copy.title || '';
    const sub = powerCard.querySelector('.power-sub');
    sub.textContent = detail || copy.sub || '';
    if (detail) sub.setAttribute('data-error', 'true');

    const btn = powerCard.querySelector('.power-btn');
    if (btn) {
      btn.textContent = copy.btn;
      btn.addEventListener('click', requestBoot);
    }

    const status = document.getElementById('nativeStatus');
    if (status) status.textContent = phase === 'gone' ? 'unavailable' : 'not booted';

    if (phase === 'off') watchForExternalBoot();
  }

  // While the Boot button is up, keep an eye on the device — it can
  // come up from anywhere: `baguette boot`, another tab, Xcode,
  // `simctl`. Without this the card would sit on "Not booted" over an
  // already-running guest until the user clicked a button they no
  // longer needed (and CoreSimulator rejects a boot in that state, so
  // the click would report a failure that isn't one).
  function watchForExternalBoot() {
    bootPollTimer = setTimeout(async () => {
      bootPollTimer = null;
      if (!powerCard || powerCard.getAttribute('data-phase') !== 'off') return;
      const meta = await fetchDeviceMeta(udid);
      if (!powerCard) return;
      if (isBooted(meta.state)) onBooted();
      else watchForExternalBoot();
    }, IDLE_POLL_MS);
  }

  // POST /simulators/<udid>/boot, then poll until CoreSimulator agrees.
  // The route is synchronous on the server side (it calls
  // `bootWithOptions:error:`), but "returned" only means the boot was
  // accepted — the guest keeps coming up afterwards, which is what the
  // poll is for.
  async function requestBoot() {
    renderPowerCard('booting');
    try {
      const r = await fetch('/simulators/' + encodeURIComponent(udid) + '/boot',
          { method: 'POST' });
      if (!r.ok) {
        // CoreSimulator refuses a boot when the device is already
        // booted. If that's why this failed, the user got what they
        // wanted — go live instead of reporting an error.
        const meta = await fetchDeviceMeta(udid);
        if (isBooted(meta.state)) { onBooted(); return; }
        const body = await r.json().catch(() => null);
        renderPowerCard('off', (body && body.error) || ('boot failed (HTTP ' + r.status + ')'));
        return;
      }
    } catch (e) {
      renderPowerCard('off', 'boot request failed — is the server still running?');
      return;
    }
    waitForBoot();
  }

  function waitForBoot(deadline) {
    const until = deadline || (Date.now() + BOOT_TIMEOUT_MS);
    bootPollTimer = setTimeout(async () => {
      if (!powerCard) return;            // card dismissed underneath us
      const meta = await fetchDeviceMeta(udid);
      if (isBooted(meta.state)) {
        onBooted();
        return;
      }
      if (Date.now() >= until) {
        renderPowerCard('off',
            'still not booted after ' + Math.round(BOOT_TIMEOUT_MS / 60000) + ' min');
        return;
      }
      waitForBoot(until);
    }, BOOT_POLL_MS);
  }

  // CoreSimulator flipped to Booted. That's earlier than SpringBoard
  // being on screen, so keep the card up (as "Starting…") until a
  // frame actually lands — with a fallback, because the stream only
  // emits when SimulatorKit composites and a device sitting on a
  // static screen may not composite anything for a while.
  function onBooted() {
    renderPowerCard('starting');
    startSession(currentFormat());
    resetToPortrait();
    firstFrameTimer = setTimeout(hidePowerCard, FIRST_FRAME_TIMEOUT_MS);
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

  // Plugin contributions — a separate rail on the right edge, drawn by
  // the host from /plugins.json. Kept apart from the device toolbar on
  // purpose: baguette ships the toolbar, plugins are code you
  // installed, and the split is a trust signal. `onHighlight` converts
  // a row's device-point frame into a box over the live screen; the
  // frame arrives in the same units as gesture coordinates, so the
  // only maths is the display scale.
  function mountPlugins() {
    if (!window.PluginPanels || !sim) return;
    pluginPanels = new window.PluginPanels({
      udid,
      // The shared right-edge stack, below baguette's own screens rail —
      // two rails claiming the same centred slot would sit on top of
      // each other. The panel and flyout inside stay `position: fixed`
      // and are unaffected by the stack; see `.right-rails`.
      mount: rightRails(),
      // The add-a-bakery modal covers the page, so it hangs off the
      // view root instead. `.right-rails` is `position: fixed` and so a
      // stacking context of its own whatever its `z-index` says —
      // anything mounted in there composites at the rail's level, which
      // is below the device.
      modalMount: document.getElementById('simNativeView') || document.body,
      isBooted: () => true,
      onHighlight: (frame) => paintPluginHighlight(frame),
      onTap: (point) => tapForPlugin(point),
      log: (msg) => console.log('[plugin]', msg),
    });
    pluginPanels.load();
  }

  // A `rowAction: "tap"` row, dispatched down the same socket every
  // other gesture uses. Wire shape matches GestureRegistry's `tap`:
  // device-point coordinates plus the device-point screen size — the
  // row's frame already arrives in that space, so there's nothing to
  // convert.
  function tapForPlugin(point) {
    if (!session || !sim || !sim.screen || !sim.screen.size) return;
    const size = sim.screen.size;
    session.send({
      type: 'tap',
      x: point.x, y: point.y,
      width: size.width, height: size.height,
    });
  }

  function paintPluginHighlight(frame) {
    let box = document.getElementById('nativePluginHighlight');
    if (!frame) { if (box) box.remove(); return; }
    if (!sim || !sim.screenArea) return;

    const area = sim.screenArea;
    const device = sim.screen.size;
    if (!device || !device.width || !device.height) return;
    const scaleX = area.clientWidth / device.width;
    const scaleY = area.clientHeight / device.height;

    if (!box) {
      box = document.createElement('div');
      box.id = 'nativePluginHighlight';
      box.className = 'plugin-highlight';
      area.appendChild(box);
    }
    box.style.left   = (frame.x * scaleX) + 'px';
    box.style.top    = (frame.y * scaleY) + 'px';
    box.style.width  = (frame.width * scaleX) + 'px';
    box.style.height = (frame.height * scaleY) + 'px';
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
          // `SimulatorState.description` — "Booted" / "Shutdown" /
          // "Booting" / "ShuttingDown" / "Creating". Absent only if
          // the device vanished between page load and this fetch.
          state: hit.state || '',
        };
      }
    } catch (_) { /* fall through */ }
    return { name: 'Simulator', runtime: '', state: '' };
  }

  function formatRuntime(raw) {
    return String(raw || '')
        .replace('com.apple.CoreSimulator.SimRuntime.', '')
        .replace(/^iOS-/, 'iOS ')
        .replace(/-/g, '.');
  }

  // The format every surface in this page streams at — phone, CarPlay,
  // watch and the 3D panel alike. Companions used to be pinned to MJPEG
  // independently of the phone, which meant a session the user had set to
  // H.264 still carried uncapped full JPEGs on its companion sockets.
  //
  // The stored value is whitelisted rather than trusted: `localStorage`
  // outlives the build that wrote it, so a format this build no longer
  // speaks would otherwise reach the socket's `format` parameter and the
  // `FrameDecoder` pick. Anything unrecognised falls back to what the
  // hardware can actually decode.
  function currentFormat() {
    const stored = localStorage.getItem('asc.simFormat');
    if (stored === 'avcc' || stored === 'mjpeg') return stored;
    return window.FrameDecoder && window.FrameDecoder.isHardwareAvailable()
        ? 'avcc' : 'mjpeg';
  }

  // Toolbar icon strip scrolls horizontally when the window is too narrow
  // to fit every control. Trackpads scroll it natively; the two chevron
  // buttons are for mouse users (a vertical wheel can't pan a horizontal
  // overflow). The arrows hide entirely when nothing overflows and each
  // dims at its end, so the bar stays clean at full width.
  // Re-measures the toolbar's overflow. Held here because the strip's
  // width no longer changes only with the window: opening a companion
  // pane narrows the toolbar too, and without a re-measure the chevrons
  // stayed hidden over a strip that had just started overflowing —
  // leaving a mouse user no way to reach the icons that had scrolled
  // out of it.
  let refreshToolbarScroll = () => {};

  // ── Toolbar clusters ─────────────────────────────────────────────
  //
  // The strip is seven CONTEXT CLUSTERS, not fifteen loose controls,
  // and when the row runs out of width a WHOLE cluster folds into one
  // menu — never an item, never a partial group. A flat per-control
  // priority queue was tried first and tore Shake off Home on a
  // tie-break between equal ranks; `docs/mockups/focus-toolbar-overflow.html`
  // runs both so the difference is visible.
  //
  // The grouping is applied at runtime rather than authored into
  // sim-native.html. That template is a flat list of buttons and reads
  // better as one; keeping the cluster definition here means the
  // membership, the fold order and the menu's idea of each control's
  // ROLE live in a single table instead of being split between HTML
  // nesting and a JS lookup.
  //
  // `role` is what the control IS, which is what its menu row has to
  // render. Flattening everything to icon + label + value turned the
  // codec picker into a caption reading "Codec  H.264" with no way to
  // reach MJPEG.
  //
  // `label` is declared rather than read off the button's `title`
  // because a tooltip and a menu row are different sentences: the
  // tooltip on the camera button says "Toggle camera control", which
  // is the right thing to say when hovering an unlabelled glyph and
  // the wrong thing to put in a list where every row is a control and
  // the verb is implied. The `title` is still the fallback, so a
  // button added without a label here still renders.
  const TOOLBAR_CLUSTERS = [
    {
      id: 'stream', label: 'Stream', fold: 3, icon: 'film',
      members: [
        { id: 'nativeStatus', label: 'Frame rate', role: 'readout' },
        { id: 'nativeFormatPicker', label: 'Codec', role: 'choice' },
      ],
    },
    {
      id: 'view', icon: 'cube',
      members: [{ id: 'native3DToggle', label: '3D view', role: 'state' }],
    },
    {
      id: 'control', label: 'Control', fold: 4, icon: 'home',
      members: [
        { id: 'nativeRotate', label: 'Rotate', role: 'action' },
        { id: 'nativeHome', label: 'Home', role: 'action' },
        { id: 'nativeAppSwitcher', label: 'App switcher', role: 'action' },
        { id: 'nativeShake', label: 'Shake', role: 'action' },
      ],
    },
    {
      id: 'simulate', label: 'Simulate', fold: 1, icon: 'wave',
      members: [
        { id: 'nativeStatusBarToggle', label: 'Status bar', role: 'state' },
        { id: 'nativeLocationToggle', label: 'Location', role: 'state' },
        { id: 'nativeCameraToggle', label: 'Camera', role: 'state' },
      ],
    },
    {
      id: 'inspect', label: 'Inspect', fold: 2, icon: 'glass',
      members: [
        { id: 'nativeAxToggle', label: 'Accessibility', role: 'state' },
        { id: 'nativeLogsToggle', label: 'Logs', role: 'state' },
      ],
    },
    {
      id: 'capture',
      members: [
        { id: 'nativeScreenshot', label: 'Screenshot', role: 'action' },
        { id: 'nativeRecordBtn', label: 'Record', role: 'action' },
        { id: 'nativeCaptureSize', role: 'mount' },
      ],
    },
  ];

  // Glyphs for the folded-cluster buttons. Every member row borrows its
  // icon from the real button it proxies, so only the cluster headers
  // need art of their own.
  const CLUSTER_ICONS = {
    film:  'M4 5h16v14H4zM4 9h16M4 15h16M8 5v14M16 5v14',
    cube:  'M12 2l9 5v10l-9 5-9-5V7z M12 12l9-5 M12 12v10 M12 12L3 7',
    home:  'M4 11l8-7 8 7v9H4z',
    wave:  'M3 12h3l2-6 3 12 3-9 2 3h5',
    glass: 'M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM16.5 16.5L21 21',
    more:  'M6 12h.01M12 12h.01M18 12h.01',
    // Rows that have no button in the bar to borrow a glyph from. Both
    // wore the Stream cluster's own film icon at first, which made
    // "Frame rate" and "Codec" look like the same control twice.
    gauge: 'M12 20a8 8 0 1 1 8-8M12 12l4.5-3',
    codec: 'M3 8h4l3 8h4l3-8h4',
  };

  const CARET_SVG =
      '<svg class="tb-caret" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
      'stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" ' +
      'width="11" height="11"><polyline points="6 9 12 15 18 9"/></svg>';

  const clusterSvg = (name) =>
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" ' +
      'stroke-linecap="round" stroke-linejoin="round" width="15" height="15">' +
      '<path d="' + CLUSTER_ICONS[name] + '"/></svg>';

  let toolbarFold = null;

  /**
   * Move the flat strip into cluster containers, once.
   *
   * Every control keeps its own element — same id, same inline
   * `onclick`, same `.active` class — so nothing about how a button
   * behaves changes; only where it sits. The fold menus are built as a
   * PROJECTION of these buttons (their icon, their `title`, their
   * active state), which is why there is no second catalogue of labels
   * to drift out of sync.
   */
  function buildToolbarClusters() {
    const controls = document.querySelector('#simNativeView .tb-controls');
    const strip = document.getElementById('nativeToolScroll');
    if (!controls || !strip || !window.Baguette || !window.Baguette._ToolbarFold) {
      return false;
    }

    // The scroller and its chevrons are what this replaces.
    ['nativeScrollLeft', 'nativeScrollRight'].forEach((id) => {
      const el = document.getElementById(id);
      if (el) el.remove();
    });

    TOOLBAR_CLUSTERS.forEach((cluster, index) => {
      if (index > 0) {
        const sep = document.createElement('span');
        sep.className = 'tb-sep';
        sep.dataset.sepFor = cluster.id;
        controls.appendChild(sep);
      }
      const host = document.createElement('span');
      host.className = 'tb-cluster';
      host.dataset.cluster = cluster.id;
      cluster.members.forEach((member) => {
        const el = document.getElementById(member.id);
        if (el) host.appendChild(el);
      });
      controls.appendChild(host);

      if (!cluster.fold) return;
      controls.appendChild(foldHost(cluster.id, cluster.label, cluster.icon));
    });

    // The merged menu sits where the folded clusters were — before
    // Capture, since every foldable cluster precedes it. Appending it
    // after Capture left it hanging off the right edge of the bar,
    // reading as an afterthought rather than as the clusters it stands
    // in for.
    const captureHost = controls.querySelector('[data-cluster="capture"]');
    const captureSep = controls.querySelector('[data-sep-for="capture"]');
    controls.insertBefore(foldHost('more', 'More controls', 'more'),
        captureSep || captureHost || null);
    strip.remove();

    toolbarFold = new window.Baguette._ToolbarFold(TOOLBAR_CLUSTERS);
    return true;
  }

  function foldHost(id, label, icon) {
    const host = document.createElement('span');
    host.className = 'tb-fold';
    host.dataset.fold = id;
    host.hidden = true;
    host.innerHTML =
        '<button type="button" class="tb-fold-btn" aria-expanded="false" ' +
        'aria-haspopup="true" title="' + label + '">' +
        clusterSvg(icon) + CARET_SVG + '</button>' +
        '<div class="tb-fold-pop" hidden></div>';
    return host;
  }

  /** Show the clusters this state keeps, and the fold buttons it needs. */
  function applyToolbarState(state) {
    const bar = document.querySelector('#simNativeView .top-bar');
    if (!bar) return;
    const folded = state.folded;
    const merged = state.merged;

    TOOLBAR_CLUSTERS.forEach((cluster) => {
      const isFolded = folded.indexOf(cluster.id) >= 0;
      const host = document.querySelector('[data-cluster="' + cluster.id + '"]');
      const sep = document.querySelector('[data-sep-for="' + cluster.id + '"]');
      const fold = document.querySelector('[data-fold="' + cluster.id + '"]');
      if (host) host.hidden = isFolded;
      if (sep) sep.hidden = isFolded;
      if (fold) fold.hidden = !isFolded || merged;
    });
    const more = document.querySelector('[data-fold="more"]');
    if (more) more.hidden = !merged;
    bar.classList.toggle('tight', state.tight);
  }

  /**
   * Ask ToolbarFold for the widest state that fits, then fill in the
   * menus for whatever ended up folded.
   *
   * Re-measuring after every candidate is what makes this exact: there
   * is no width table to keep in sync with the CSS, and it stays right
   * when a device name is long or a webfont lands late.
   */
  function layoutToolbar() {
    const bar = document.querySelector('#simNativeView .top-bar');
    if (!bar || !toolbarFold) return;

    restoreClusterMembers();
    bar.classList.add('measuring');
    const state = toolbarFold.plan((candidate) => {
      applyToolbarState(candidate);
      return bar.scrollWidth <= bar.clientWidth + 1;
    });
    bar.classList.remove('measuring');
    fillFoldMenus(state);
  }

  /**
   * Put every member element back in its own cluster, in declared
   * order.
   *
   * A `choice` row MOVES the real control into the menu rather than
   * copying it — a cloned picker would be a second `#nativeFormatPicker`
   * with none of the page's handlers on it. That means the menu owns
   * the only copy while it is folded, so wiping the popovers without
   * this first deleted the codec picker outright: `getElementById`
   * returned null for the rest of the session and the Stream menu
   * silently lost its one interactive row. Restore, then rebuild.
   */
  function restoreClusterMembers() {
    TOOLBAR_CLUSTERS.forEach((cluster) => {
      const host = document.querySelector('[data-cluster="' + cluster.id + '"]');
      if (!host) return;
      cluster.members.forEach((member) => {
        const el = document.getElementById(member.id);
        if (el && el.parentElement !== host) host.appendChild(el);
      });
    });
  }

  /** Build the menu bodies once, for the state that won. */
  function fillFoldMenus(state) {
    restoreClusterMembers();
    document.querySelectorAll('#simNativeView .tb-fold-pop')
        .forEach((pop) => { pop.innerHTML = ''; });

    const foldedClusters = TOOLBAR_CLUSTERS
        .filter((c) => state.folded.indexOf(c.id) >= 0);

    if (state.merged) {
      const pop = document.querySelector('[data-fold="more"] .tb-fold-pop');
      if (pop) {
        foldedClusters.forEach((cluster) => pop.appendChild(accordion(cluster)));
      }
      return;
    }
    foldedClusters.forEach((cluster) => {
      const pop = document.querySelector(
          '[data-fold="' + cluster.id + '"] .tb-fold-pop');
      if (!pop) return;
      cluster.members.forEach((m) => {
        const row = menuRow(m);
        if (row) pop.appendChild(row);
      });
    });
  }

  /**
   * One cluster as a collapsed accordion section.
   *
   * `<details>` will happily open all four at once, which puts all
   * thirteen rows back and undoes the reason for having an accordion —
   * so `name=` groups them where it is supported, and `syncAccordion`
   * enforces it everywhere else.
   */
  function accordion(cluster) {
    const details = document.createElement('details');
    details.className = 'tb-acc';
    details.setAttribute('name', 'nativeToolbarAcc');
    const summary = document.createElement('summary');
    summary.innerHTML = clusterSvg(cluster.icon) +
        '<span>' + cluster.label + '</span>' +
        '<span class="tb-acc-n">' + cluster.members.length + '</span>' + CARET_SVG;
    details.appendChild(summary);
    const body = document.createElement('div');
    body.className = 'tb-acc-body';
    cluster.members.forEach((m) => {
      const row = menuRow(m);
      if (row) body.appendChild(row);
    });
    details.appendChild(body);
    return details;
  }

  /**
   * A folded control as a menu row, rendered for what it IS.
   *
   *   action    a button; clicking the row clicks the real one
   *   state     the same, plus a dot when it is currently on
   *   choice    the real control, moved in — a value you cannot change
   *             is a caption pretending to be a control
   *   readout   no hover, no pointer: nothing happens when pressed
   *
   * `state` used to draw a SWITCH, which was wrong twice over. Every
   * control that can reach this menu — status bar, location, camera,
   * accessibility, logs — opens a PANEL; a switch says "a setting you
   * flip and leave", and these are disclosures. And the switch made
   * the row keep the menu open so you could see it move, which left
   * the panel you had just opened sitting behind the menu covering it.
   * A dot reports the same state without claiming to be a setting, and
   * every row now closes the menu, because every row reveals something
   * the menu is standing on top of.
   */
  function menuRow(member) {
    const source = document.getElementById(member.id);
    if (!source) return null;
    const label = member.label || source.getAttribute('title') || member.id;

    if (member.role === 'readout') {
      const row = document.createElement('div');
      row.className = 'tb-read';
      row.innerHTML = clusterSvg('gauge') + '<span>' + label + '</span>' +
          '<span class="tb-val"></span>';
      row.querySelector('.tb-val').textContent = source.textContent || '—';
      return row;
    }

    if (member.role === 'choice') {
      const row = document.createElement('div');
      row.className = 'tb-choice';
      row.innerHTML = clusterSvg('codec') + '<span>' + label + '</span>';
      // The real picker is moved in, not copied: it keeps its handlers,
      // its `.active` pill, and its identity as the one control the
      // rest of the page already talks to.
      row.appendChild(source);
      return row;
    }

    const row = document.createElement('button');
    row.type = 'button';
    row.className = 'tb-row' + (source.classList.contains('active') ? ' on' : '');
    const glyph = source.querySelector('svg');
    row.innerHTML = (glyph ? glyph.outerHTML : clusterSvg('more')) +
        '<span>' + label + '</span>' +
        (member.role === 'state' ? '<span class="tb-dot"></span>' : '');
    row.addEventListener('click', () => {
      source.click();
      closeFoldMenus();
    });
    return row;
  }

  function closeFoldMenus() {
    document.querySelectorAll('#simNativeView .tb-fold-pop')
        .forEach((n) => { n.hidden = true; });
    document.querySelectorAll('#simNativeView .tb-fold-btn')
        .forEach((n) => n.setAttribute('aria-expanded', 'false'));
  }

  function wireToolbarScroll() {
    if (!buildToolbarClusters()) return;

    document.addEventListener('click', (event) => {
      const btn = event.target.closest('#simNativeView .tb-fold-btn');
      if (btn) {
        const pop = btn.parentElement.querySelector('.tb-fold-pop');
        const open = btn.getAttribute('aria-expanded') === 'true';
        closeFoldMenus();
        if (!open) {
          pop.hidden = false;
          btn.setAttribute('aria-expanded', 'true');
        }
        return;
      }
      const summary = event.target.closest('#simNativeView .tb-acc > summary');
      if (summary) {
        // `name=` handles this in Chrome 120+/Safari 17.4+; do it by
        // hand so older engines behave the same.
        const self = summary.parentElement;
        setTimeout(() => {
          if (!self.open) return;
          self.parentElement.querySelectorAll('.tb-acc').forEach((d) => {
            if (d !== self) d.open = false;
          });
        }, 0);
        return;
      }
      if (!event.target.closest('#simNativeView .tb-fold')) closeFoldMenus();
    });

    refreshToolbarScroll = layoutToolbar;
    window.addEventListener('resize', layoutToolbar);
    // Re-measure once layout settles (fonts, device frame, format pills).
    requestAnimationFrame(layoutToolbar);
    setTimeout(layoutToolbar, 400);
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
    // Record is Screenshot's moving-picture sibling: same source, same
    // picked size, one toggle instead of a one-shot.
    window.__nativeRecord = () => { void toggleRecording(); };
    window.__nativeClearRecordings = () => clearRecordings();
    window.__nativeHideRecordings = () => hideRecordings();
    window.__nativeClose = () => {
      // Shutting the window from inside a popup-style URL: try
      // window.close (only works for script-opened tabs) then fall
      // back to navigating to the list.
      try { window.close(); } catch (_) { /* ignore */ }
      if (!window.closed) location.href = '/simulators';
    };
    window.__nativeSetFormat = (next) => {
      if (next !== 'avcc' && next !== 'mjpeg') return;
      const current = currentFormat();
      const view = document.getElementById('simNativeView');
      if (current === next && (session ||
          (view && view.getAttribute('data-render3d') === 'open'))) return;
      localStorage.setItem('asc.simFormat', next);
      reflectFormat(next);
      if (view && view.getAttribute('data-render3d') === 'open') {
        if (render3DPanel) render3DPanel.setFormat(next);
      } else {
        startSession(next);
      }
    };
    window.__nativeToggleTheme = () => {
      setTheme(currentTheme() === 'light' ? 'dark' : 'light');
    };
    window.__nativeToggleLogs = () => toggleLogs();
    window.__nativeToggleCamera = () => toggleCamera();
    window.__nativeToggleStatusBar = () => toggleStatusBar();
    window.__nativeToggleLocation = () => toggleLocation();
    window.__nativeToggleNetwork = () => toggleNetwork();
    window.__nativeToggle3D = () => toggle3D();
    window.__nativeToggle3DInspector = () => toggle3DInspector();
    // The watch's hardware buttons. Same `button` envelope the phone's
    // bezel buttons use, but down the watch's own socket — the press
    // has to reach the watch's HID, not the phone we happen to be
    // looking at beside it. Silently no-ops when the pane is closed;
    // there is no button row on screen to press in that case.
    window.__nativeWatchButton = (name) => {
      if (watchSession) watchSession.send({ type: 'button', button: name });
    };
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

    // Shake — fires a UIKit motionShake on the frontmost app
    // (shake-to-undo etc). POSTs to `/simulators/<udid>/shake`; the
    // server delegates to `simulator.shake().shake()`, backed by
    // `simctl spawn notifyutil`. Unlike rotate there's no visual state
    // to mirror — the motion event lives entirely in the guest — so
    // this is a pure fire-and-forget POST.
    window.__nativeShake = () => {
      const url = '/simulators/' + encodeURIComponent(udid) + '/shake';
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

  // Network-conditioning card — same lazy-mount pattern as the status-bar
  // card, with one difference that matters: the toolbar's armed dot is kept
  // in sync whether or not the card has ever been opened. A forgotten
  // throttle does not announce itself — it presents as "the app is slow",
  // possibly days later — so the indicator cannot depend on the user
  // happening to open the panel.
  function toggleNetwork() {
    const view = document.getElementById('simNativeView');
    const host = document.getElementById('nativeNetworkHost');
    const btn  = document.getElementById('nativeNetworkToggle');
    const sheet = document.getElementById('nativeNetworkSheet');
    const open = view && view.getAttribute('data-network') === 'open';
    if (!view || !host) return;
    // `aria-hidden` tracks the card, rather than being pinned true in the
    // markup: a card that is on screen but hidden from the a11y tree is
    // unreachable to a screen reader and invisible to anything driving the
    // page through it.
    if (open) {
      view.removeAttribute('data-network');
      if (btn) btn.classList.remove('active');
      // `inert` as well as `aria-hidden`: the closed card is only faded out
      // by CSS, so without it the controls stay focusable and tabbing walks
      // into a panel nobody can see.
      if (sheet) { sheet.setAttribute('aria-hidden', 'true'); sheet.inert = true; }
    } else {
      view.setAttribute('data-network', 'open');
      if (btn) btn.classList.add('active');
      if (sheet) { sheet.setAttribute('aria-hidden', 'false'); sheet.inert = false; }
      if (!networkPanel && window.NetworkPanel && udid) {
        host.innerHTML = '';
        networkPanel = new window.NetworkPanel();
        networkPanel.onArmedChange = (form) =>
          markNetworkArmed(form.isConditioning, form.describe());
        networkPanel.attach(host, udid);
      } else if (networkPanel) {
        networkPanel.refresh();
      }
    }
  }

  function markNetworkArmed(armed, summary) {
    const btn = document.getElementById('nativeNetworkToggle');
    if (!btn) return;
    btn.classList.toggle('conditioning', !!armed);
    // The amber dot is the whole warning, and a dot says nothing to a screen
    // reader. Put the state in the accessible name too, so "a throttle is
    // on" is available without seeing it.
    const label = armed
      ? `Network conditioning on${summary ? ` — ${summary}` : ''}`
      : 'Network conditioning off';
    btn.setAttribute('aria-label', label);
    btn.setAttribute('title', label);
  }

  // Poll the device's conditioning state independently of the card. This is
  // the safety net: the CLI and the HTTP route can arm a throttle this page
  // never saw, and the browser is where someone is most likely to be looking
  // when they wonder why everything is slow.
  function watchNetworkArmed() {
    if (!udid || networkArmedTimer) return;
    const poll = async () => {
      try {
        const res = await fetch(`/simulators/${encodeURIComponent(udid)}/network`);
        if (res.ok) {
          const state = await res.json();
          markNetworkArmed(state.active, state.summary);
        }
      } catch (e) { /* leave the indicator as it was */ }
    };
    poll();
    networkArmedTimer = setInterval(poll, 5000);
  }

  // Location card — same lazy-mount pattern as the status-bar card.
  // LocationPanel hangs a Leaflet map that POSTs `simctl location`
  // set/start/clear. Reopening re-measures the map (it may have been
  // laid out at zero size while the card was faded out).
  function toggleLocation() {
    const view = document.getElementById('simNativeView');
    const host = document.getElementById('nativeLocationHost');
    const btn  = document.getElementById('nativeLocationToggle');
    const open = view && view.getAttribute('data-location') === 'open';
    if (!view || !host) return;
    if (open) {
      view.removeAttribute('data-location');
      if (btn) btn.classList.remove('active');
    } else {
      view.setAttribute('data-location', 'open');
      if (btn) btn.classList.add('active');
      if (!locationPanel && window.LocationPanel && udid) {
        host.innerHTML = '';
        locationPanel = new window.LocationPanel();
        locationPanel.attach(host, udid);
      } else if (locationPanel) {
        locationPanel.refresh();
      }
    }
  }

  // Live 3D is a main-view mode, not a duplicate preview. Its WebSocket
  // replaces the 2D StreamSession while open and carries both MJPEG
  // frames and the same inbound input/control envelopes.
  function toggle3D() {
    const view = document.getElementById('simNativeView');
    const host = document.getElementById('native3DHost');
    const stage = document.getElementById('native3DStage');
    const btn = document.getElementById('native3DToggle');
    const open = view && view.getAttribute('data-render3d') === 'open';
    if (!view || !host || !stage || !sim) return;
    // The canvas being recorded is about to be swapped for the other
    // mode's, and the two are different surfaces at different sizes.
    cancelRecording('switched between 2D and 3D');
    // `open` is the state we're LEAVING, so it doubles as "will be 2D".
    reflect3DCaptureControls(open);
    if (open) {
      view.removeAttribute('data-render3d');
      view.removeAttribute('data-render3d-inspector');
      if (btn) btn.classList.remove('active');
      if (render3DPanel) render3DPanel.stop();
      startSession(currentFormat());
    } else {
      if (session) {
        session.stop();
        session = null;
      }
      view.setAttribute('data-render3d', 'open');
      const inspectorOpen = localStorage.getItem('asc.3dInspector') !== 'closed';
      if (inspectorOpen) {
        view.setAttribute('data-render3d-inspector', 'open');
      }
      const sheet = document.getElementById('native3DSheet');
      if (sheet) sheet.setAttribute('aria-hidden', inspectorOpen ? 'false' : 'true');
      if (btn) btn.classList.add('active');
      const status = document.getElementById('nativeStatus');
      if (status) status.textContent = '3D live';
      // Told BEFORE the stream starts: a picked size raises the
      // stream's pixel budget (Sim3DPanel.streamBudget), so setting it
      // afterwards would open at the ordinary budget and restart.
      if (render3DPanel && typeof render3DPanel.setCaptureSettings === 'function') {
        render3DPanel.setCaptureSettings(captureSettings());
      }
      if (!render3DPanel && window.Sim3DPanel && udid) {
        render3DPanel = new window.Sim3DPanel();
        render3DPanel.setCaptureSettings(captureSettings());
        render3DPanel.attach(host, stage, udid, {
          deviceSize: { width: sim.screen.size.width, height: sim.screen.size.height },
          format: currentFormat(),
          background: live3DBackground(),
          onFps: (fps) => {
            const status = document.getElementById('nativeStatus');
            if (status) status.textContent = fps + ' fps · 3D';
          },
        });
      } else if (render3DPanel) {
        render3DPanel.background = live3DBackground();
        render3DPanel.start();
      }
    }
  }

  // The inspector is a tool surface, not the 3D session owner. Collapsing it
  // must leave the model, decoder, socket, pose, zoom, and variant untouched.
  function toggle3DInspector() {
    const view = document.getElementById('simNativeView');
    const sheet = document.getElementById('native3DSheet');
    if (!view || view.getAttribute('data-render3d') !== 'open') return;
    const open = view.getAttribute('data-render3d-inspector') === 'open';
    if (open) {
      view.removeAttribute('data-render3d-inspector');
      localStorage.setItem('asc.3dInspector', 'closed');
    } else {
      view.setAttribute('data-render3d-inspector', 'open');
      localStorage.setItem('asc.3dInspector', 'open');
    }
    if (sheet) sheet.setAttribute('aria-hidden', open ? 'true' : 'false');
  }

  function wireUnload() {
    window.addEventListener('beforeunload', () => {
      try { hidePowerCard(); } catch (_) { /* ignore */ }
      try { cancelRecording('page unloading'); } catch (_) { /* ignore */ }
      try { clearRecordings(); } catch (_) { /* ignore */ }
      try { if (session) session.stop(); } catch (_) { /* ignore */ }
      try { if (carplaySession) carplaySession.stop(); } catch (_) { /* ignore */ }
      try { if (carplayScreen) carplayScreen.detach(); } catch (_) { /* ignore */ }
      try { if (carplayFrame) carplayFrame.detach(); } catch (_) { /* ignore */ }
      carplayFrame = null;
      try { if (watchSession) watchSession.stop(); } catch (_) { /* ignore */ }
      try { if (watchScreen) watchScreen.detach(); } catch (_) { /* ignore */ }
      try { if (screensRail) screensRail.detach(); } catch (_) { /* ignore */ }
      try { if (sim) sim.detach(); } catch (_) { /* ignore */ }
      try { if (axInspector) axInspector.detach(); } catch (_) { /* ignore */ }
      try { if (cameraPanel) cameraPanel.detach(); } catch (_) { /* ignore */ }
      try { if (statusBarPanel) statusBarPanel.detach(); } catch (_) { /* ignore */ }
      try { if (locationPanel) locationPanel.detach(); } catch (_) { /* ignore */ }
      try { if (networkPanel) networkPanel.detach(); } catch (_) { /* ignore */ }
      try { if (networkArmedTimer) clearInterval(networkArmedTimer); } catch (_) { /* ignore */ }
      try { if (render3DPanel) render3DPanel.detach(); } catch (_) { /* ignore */ }
    });
  }

  // --- Capture: one picked size, two verbs, two modes ---------------
  //
  // "App Store 6.9″" / "Square" / "16:9" is chosen once, on the chip in
  // the toolbar, and every capture on this page reads it — in 2D and in
  // 3D alike. The vocabulary is shared with the HTTP routes and the CLI
  // and lives in Resources/Web/capture/; see
  // docs/features/capture-size.md. Nothing here reimplements any of it.
  //
  // Who applies it differs by verb, because who owns the output canvas
  // differs: a screenshot is composed here, a 3D Save Frame is rendered
  // server-side from settings handed to Sim3DPanel, and a recording is
  // sized by BrowserRecorder's own compose canvas — which is why the
  // recording's filename carries no size slug.
  //
  // Those modules are pulled in at runtime rather than with a <script>
  // tag, because this page has no <head> of its own: sim.html carries
  // the page's script tags, and `fetchTemplate` deliberately drops the
  // ones inside sim-native.html. Anything already on the page (sim.html
  // loads /recorder.js today) is left alone — the guard is the global
  // the module hangs itself on, not the URL, so this stays correct
  // whichever page happens to have loaded it first.
  const CAPTURE_MODULES = [
    ['/capture/capture-size.js', () => window.Baguette && window.Baguette._CaptureSize],
    ['/capture/capture-settings.js', () => window.Baguette && window.Baguette._CaptureSettings],
    ['/capture/capture-composer.js', () => window.Baguette && window.Baguette._CaptureComposer],
    ['/capture/capture-size-menu.js', () => window.CaptureSizeMenu],
    ['/recorder.js', () => window.BrowserRecorder],
  ];

  let captureMenu = null;   // CaptureSizeMenu — the size chip in the toolbar

  // Recording state, mirroring sim-stream.js's `recordingState`:
  //   recorder  : BrowserRecorder while a recording is in flight
  //   active    : true between start() and stop()
  //   startedAt : ms timestamp behind the mm:ss readout
  //   timer     : interval handle ticking that readout
  //   entries   : finished artifacts — Blob URLs we own and must revoke
  const recordingState = {
    recorder: null, active: false, startedAt: 0, timer: null, entries: [],
    notice: '',   // why the last take ended without producing a file
  };

  let _captureModulesPromise = null;
  function ensureCaptureModules() {
    if (_captureModulesPromise) return _captureModulesPromise;
    _captureModulesPromise = (async () => {
      for (const [src, present] of CAPTURE_MODULES) {
        if (present()) continue;
        await loadScript(src);
      }
    })();
    return _captureModulesPromise;
  }

  function loadScript(src) {
    return new Promise((resolve) => {
      const el = document.createElement('script');
      el.src = src;
      el.onload = () => resolve(true);
      el.onerror = () => { console.warn('[native] failed to load', src); resolve(false); };
      document.head.appendChild(el);
    });
  }

  function mountCaptureUI() {
    const host = document.getElementById('nativeCaptureSize');
    if (host && window.CaptureSizeMenu && !captureMenu) {
      captureMenu = new window.CaptureSizeMenu({
        storageKey: 'asc.capture.native',
        // Three controls that only make sense in 2D — see
        // `reflect3DCaptureControls` for why. `toggle3D` flips them.
        showFrameToggle: !is3DOpen(),
        showFitToggle: !is3DOpen(),
        showBackgroundToggle: !is3DOpen(),
        // The popover shows each preset's resolved pixels, so it has to
        // be told what the *composite* is — the bezel viewport when the
        // frame is on, the bare canvas when it isn't.
        sourceSize: () => compositeSourceSize(),
        onChange: (settings) => {
          refreshToolbarScroll();
          // The 3D render is produced server-side, so the size has to
          // travel with the request rather than being applied to a
          // canvas we hold.
          if (render3DPanel && typeof render3DPanel.setCaptureSettings === 'function') {
            render3DPanel.setCaptureSettings(settings);
          }
        },
      });
      captureMenu.mount(host);
    }
    // A Record button that can't record is worse than no Record button.
    const btn = document.getElementById('nativeRecordBtn');
    if (btn) {
      btn.hidden = !(window.BrowserRecorder && window.BrowserRecorder.isAvailable());
    }
    refreshToolbarScroll();
  }

  /**
   * Show only the picker controls that mean something in the current
   * mode. All three are read by `_renderPopover` at open time, so
   * flipping them on the live instance is enough.
   *
   * In 3D:
   *   • bezel — the rendered frame already carries the device body, so
   *     compositing a second one would draw the phone twice;
   *   • fit — on the `render-3d.png` route `fit` is the UV placement of
   *     the app screenshot on the device's screen mesh, not canvas
   *     placement, so `contain` would letterbox the app *inside* the
   *     phone's display. Canvas placement there is the camera's job;
   *   • background — the render fills its own canvas with the scene
   *     background already.
   */
  function reflect3DCaptureControls(twoD) {
    if (!captureMenu) return;
    captureMenu.showFrameToggle = twoD;
    captureMenu.showFitToggle = twoD;
    captureMenu.showBackgroundToggle = twoD;
  }

  function is3DOpen() {
    const view = document.getElementById('simNativeView');
    return !!(view && view.getAttribute('data-render3d') === 'open');
  }

  function captureSettings() {
    if (captureMenu) return captureMenu.settings;
    const B = window.Baguette;
    // `new CaptureSettings()` dereferences `_CaptureSize` in its own
    // constructor, and `loadScript` resolves rather than rejects on a
    // 404 — so a half-loaded vocabulary is reachable, and checking only
    // the one global would throw right past the fallback below.
    if (!B || !B._CaptureSettings || !B._CaptureSize) return null;
    return new B._CaptureSettings();
  }

  /**
   * What a capture reads from, in whichever mode is actually showing.
   *
   * 3D is bezel-less on purpose: the server-rendered frame already
   * contains the device body, so compositing a second bezel over it
   * would draw the phone twice. `frameImg: null, screen: null` is how
   * both CaptureComposer and BrowserRecorder spell "bare canvas".
   *
   * @returns {{canvas, frameImg, screen, overlayHost, mode}|null}
   */
  function activeCaptureSource() {
    if (is3DOpen()) {
      const canvas = render3DPanel && render3DPanel.canvas;
      // `data-painted` is Sim3DPanel's own "a frame has landed" flag;
      // without it the canvas is a blank allocation.
      if (!canvas || !canvas.width || !canvas.hasAttribute('data-painted')) return null;
      return {
        canvas, frameImg: null, screen: null, overlayHost: null, mode: '3d',
      };
    }
    if (!sim || !sim.canvas || !sim.canvas.width) return null;
    const settings = captureSettings();
    const withFrame = settings ? settings.withFrame : false;
    return {
      canvas: sim.canvas,
      frameImg: withFrame && sim._bezel ? sim._bezel.frameImg : null,
      screen: withFrame ? sim.screen.def : null,
      overlayHost: sim.pinchOverlayContainer,
      mode: '2d',
    };
  }

  /**
   * The composite at capture scale — `CaptureComposer.composite` grows
   * the bezel until the screen cutout is 1:1 with the arriving frames,
   * so an App Store size resamples from the full framebuffer rather than
   * from a ~3x-downsampled thumbnail. Returns `{width, height, scale}`.
   */
  function activeComposite() {
    const source = activeCaptureSource();
    const Composer = window.Baguette && window.Baguette._CaptureComposer;
    if (!source || !Composer) return null;
    return Composer.composite(source.frameImg, source.screen, source.canvas);
  }

  /** The composite's size at capture scale, before the picked size. */
  function compositeSourceSize() {
    const composite = activeComposite();
    if (!composite) return null;
    return { width: composite.width, height: composite.height };
  }

  // Take a snapshot and trigger a download, composed at whatever the
  // size chip says. We skip CaptureGallery here — the focus chrome has
  // nowhere to put a thumbnail strip, and the user just wants the file.
  //
  // In 3D the picked size is the SERVER's job, not the composer's. The
  // stage canvas is a wide, mostly-empty frame with a small device
  // floating in it — letterboxing that whole frame into an App Store
  // 6.9″ canvas leaves a postage-stamp phone adrift on white, because
  // `contain` scales the empty stage, not the device inside it. Framing
  // a 3D shot is the camera's job, and only the renderer has a camera.
  // `Sim3DPanel.download` re-renders the exact pose off the stream at
  // the picked size and falls back to the live frame if the route
  // fails, so the toolbar button and the panel's own Save Frame produce
  // the same file — which is what a user who set the size once expects.
  function downloadSnapshot() {
    if (is3DOpen() && render3DPanel && typeof render3DPanel.download === 'function') {
      if (typeof render3DPanel.setCaptureSettings === 'function') {
        render3DPanel.setCaptureSettings(captureSettings());
      }
      render3DPanel.download();
      return;
    }
    const source = activeCaptureSource();
    if (!source) return;
    const settings = captureSettings();
    const Composer = window.Baguette && window.Baguette._CaptureComposer;
    // The capture modules failed to load: still hand over the frame at
    // native size rather than doing nothing at all.
    if (!settings || !Composer) {
      source.canvas.toBlob((blob) => {
        if (blob) saveBlob(blob, `${deviceSlug()}-${captureStamp()}.png`);
      }, 'image/png');
      return;
    }

    const composite = Composer.composite(source.frameImg, source.screen, source.canvas);
    if (!composite.width || !composite.height) return;
    const plan = settings.plan(composite.width, composite.height);
    if (!plan.width || !plan.height) return;

    const out = document.createElement('canvas');
    out.width = plan.width;
    out.height = plan.height;
    const ctx = out.getContext('2d');
    // A ratio preset only ever grows the canvas, but a fixed App Store
    // size can ask for a real rescale — take the browser's good
    // resampler rather than its default nearest-neighbour.
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';
    Composer.compose(ctx, plan, settings.effectiveBackground, (c) => {
      // `compose` has already set the transform for a source the size of
      // the grown composite; `paintComposite` paints at the bezel's own
      // size, so the supersample factor goes on here.
      if (composite.scale !== 1) c.scale(composite.scale, composite.scale);
      Composer.paintComposite(c, {
        frameImg: source.frameImg,
        screen: source.screen,
        sourceCanvas: source.canvas,
      });
    });
    out.toBlob((blob) => {
      if (!blob) return;
      saveBlob(blob,
        `${deviceSlug()}-${captureStamp()}-${settings.slug(plan.width, plan.height)}.png`);
    }, 'image/png');
  }

  // --- Recording ----------------------------------------------------

  /**
   * The settings a recording should run with, which are not always the
   * ones on the chip.
   *
   * In 3D the source is a stage — a device standing in empty margins —
   * so `contain` shrinks the device into the emptiness rather than
   * cropping the emptiness away. `Sim3DPanel.recordingFit` decides how
   * far it is safe to crop. A screenshot doesn't need this: it
   * re-renders server-side at the exact size, framed by the camera.
   * 2D is untouched — there the source canvas IS the device.
   */
  function recordingSettings(source) {
    const settings = captureSettings();
    if (!settings || !source || source.mode !== '3d') return settings;
    const Panel = window.Sim3DPanel;
    if (!Panel || typeof Panel.recordingFit !== 'function') return settings;
    const fit = Panel.recordingFit(settings, source.canvas);
    return fit === settings.fit ? settings : settings.with({ fit });
  }

  function toggleRecording() {
    if (recordingState.active) return stopRecording();
    return startRecording();
  }

  function startRecording() {
    if (!window.BrowserRecorder || !window.BrowserRecorder.isAvailable()) return;
    const source = activeCaptureSource();
    if (!source) return;
    try {
      const rec = new window.BrowserRecorder({
        canvas: source.canvas,
        // In 3D both of these are null, which BrowserRecorder already
        // reads as "record the bare canvas" — the same result a
        // dedicated `bezel: false` option gives, without depending on
        // it having landed.
        frameImg: source.frameImg,
        screen: source.screen,
        overlayHost: source.overlayHost,
        // Forward-compatible hint: sizing a recording is the recorder's
        // job (it owns the compose canvas), and it ignores keys it
        // doesn't know. Screenshots are sized here, above.
        settings: recordingSettings(source),
        fps: 60,
      });
      rec.start();
      recordingState.recorder = rec;
      recordingState.active = true;
      // Last take's "discarded" line is stale the moment a new one runs.
      recordingState.notice = '';
      renderRecordings();
      recordingState.startedAt = Date.now();
      if (recordingState.timer) clearInterval(recordingState.timer);
      recordingState.timer = setInterval(updateRecordButton, 250);
      updateRecordButton();
    } catch (err) {
      console.warn('[native] recording failed to start:', err);
      resetRecordingState();
      updateRecordButton();
    }
  }

  async function stopRecording() {
    const rec = recordingState.recorder;
    // Optimistic UI: the button leaves the recording state the instant
    // the user clicks, because MediaRecorder's final chunk can take a
    // beat to land on a longer take.
    recordingState.recorder = null;
    resetRecordingState();
    updateRecordButton();
    if (!rec) return;
    try {
      const artifact = await rec.stop();
      if (!artifact || typeof artifact.url !== 'string') return;
      // Name it after the device, the way the screenshot is —
      // BrowserRecorder only knows a timestamp. Deliberately WITHOUT a
      // size slug: the recorder sizes its own compose canvas, so
      // stamping the picked size into the name would be a claim about
      // bytes we didn't produce.
      const ext = (artifact.filename || '').split('.').pop() || 'webm';
      artifact.filename = `${deviceSlug()}-${captureStamp()}.${ext}`;
      recordingState.entries.unshift(artifact);
      recordingState.notice = '';
      renderRecordings();
    } catch (err) {
      console.warn('[native] recording failed to stop:', err);
    }
  }

  /// Drop an in-flight recording on the floor. The source canvas is
  /// about to stop being the thing the user asked to record — the
  /// stream restarted, the device changed, or they flipped 2D↔3D — and
  /// a recorder left running would keep sampling a dead or wrong
  /// surface.
  function cancelRecording(reason) {
    if (!recordingState.recorder && !recordingState.active) return;
    try {
      if (recordingState.recorder) recordingState.recorder.cancel();
    } catch (_) { /* already torn down */ }
    recordingState.recorder = null;
    resetRecordingState();
    updateRecordButton();
    console.log('[native] recording cancelled:', reason);
    // Say so where the file would have appeared. A format-pill click is
    // one pixel from the record button and throws the take away; a
    // button that just stops looking pressed reads as "the click didn't
    // register", not "your recording is gone".
    recordingState.notice = `Recording discarded — ${reason}.`;
    renderRecordings();
  }

  function resetRecordingState() {
    recordingState.active = false;
    recordingState.startedAt = 0;
    if (recordingState.timer) {
      clearInterval(recordingState.timer);
      recordingState.timer = null;
    }
  }

  function updateRecordButton() {
    const btn = document.getElementById('nativeRecordBtn');
    if (!btn) return;
    const was = btn.classList.contains('recording');
    btn.classList.toggle('recording', recordingState.active);
    btn.setAttribute('aria-pressed', recordingState.active ? 'true' : 'false');
    btn.title = recordingState.active ? 'Stop recording' : 'Record video';
    btn.setAttribute('aria-label',
      recordingState.active ? 'Stop recording' : 'Start recording');
    const timer = document.getElementById('nativeRecordTimer');
    if (timer) {
      timer.textContent = recordingState.active
        ? formatElapsed((Date.now() - recordingState.startedAt) / 1000)
        : '';
    }
    // The mm:ss readout appears and disappears with the state, which
    // changes the button's width — and therefore whether the icon strip
    // overflows. Without a re-measure the scroll chevrons go stale.
    if (was !== recordingState.active) refreshToolbarScroll();
  }

  function renderRecordings() {
    const dock = document.getElementById('nativeRecordDock');
    const list = document.getElementById('nativeRecordList');
    if (!dock || !list) return;
    if (!recordingState.entries.length && !recordingState.notice) {
      dock.removeAttribute('data-open');
      list.innerHTML = '';
      return;
    }
    const notice = recordingState.notice
      ? `<p class="rec-note">${escapeAttribute(recordingState.notice)}</p>`
      : '';
    list.innerHTML = notice + recordingState.entries.map((e) => `
      <a href="${e.url}" download="${escapeAttribute(e.filename)}"
         title="Download ${escapeAttribute(e.filename)}">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
             stroke-linecap="round" stroke-linejoin="round" width="12" height="12">
          <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
          <polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/>
        </svg>
        <span>${formatElapsed(e.durationSeconds)}</span>
        <span class="rec-meta">${formatBytes(e.bytes)}</span>
      </a>`).join('');
    dock.setAttribute('data-open', '');
  }

  /// Empty the dock and hand every Blob back to the browser. A recorded
  /// minute is tens of megabytes held live by its URL; a session that
  /// records all afternoon and never revokes keeps every one of them.
  /// Destructive and unrecoverable, which is why its control is a
  /// labelled "Clear" and not the ✕ beside it.
  function clearRecordings() {
    recordingState.entries.forEach((e) => {
      if (e.url && e.url.startsWith('blob:')) URL.revokeObjectURL(e.url);
    });
    recordingState.entries = [];
    recordingState.notice = '';
    renderRecordings();
  }

  /// Put the dock away without touching what's in it. Reopens itself
  /// the next time a recording lands.
  function hideRecordings() {
    recordingState.notice = '';
    const dock = document.getElementById('nativeRecordDock');
    if (dock) dock.removeAttribute('data-open');
  }

  function formatElapsed(seconds) {
    const total = Math.max(0, Math.round(Number(seconds) || 0));
    const m = Math.floor(total / 60);
    const s = total % 60;
    return `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
  }

  function formatBytes(bytes) {
    const n = Number(bytes) || 0;
    if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`;
    return `${(n / (1024 * 1024)).toFixed(1)} MB`;
  }

  function escapeAttribute(text) {
    return String(text == null ? '' : text)
      .replace(/[&<>"]/g, (c) => (
        { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]
      ));
  }

  function deviceSlug() {
    return (deviceName || 'simulator').replace(/[^A-Za-z0-9._-]/g, '_');
  }

  function captureStamp() {
    return new Date().toISOString().replace(/[:.]/g, '-');
  }

  function saveBlob(blob, filename) {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    requestAnimationFrame(() => {
      URL.revokeObjectURL(a.href);
      a.remove();
    });
  }

  console.log('[Baguette] sim-native.js active for', udid);
})();
