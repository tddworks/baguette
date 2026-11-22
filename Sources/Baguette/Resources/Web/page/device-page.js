// page/device-page.js — focus mode at /devices/<udid>.
//
// Activates only when the page is loaded directly with a UDID in the
// path. Renders a macOS-Simulator-style window chrome (traffic
// lights, centered device title, top-right Home / Screenshot / Lock
// toolbar) wrapping a focused live-stream surface. Reuses the same
// modules as page/devices-stream.js — DeviceFrame, FrameDecoder, StreamSession,
// SimInput, MouseGestureSource, PinchOverlay — without the sidebar.
//
// Sets `window.__baguetteNativeMode = true` *synchronously* so
// page/devices-list.js (loaded later) can early-return and not paint the list
// underneath us.
(function () {
  'use strict';

  // --- Activation gate ---------------------------------------------
  // Match `/devices/<udid>`; reject `/simulators` and
  // `/devices/`. UDIDs never contain `/`, so the second segment
  // being non-empty is the discriminator.
  function deepLinkUdid() {
    const parts = location.pathname.split('/').filter(Boolean);
    if (parts.length !== 2) return null;
    if (parts[0] !== 'simulators' && parts[0] !== 'devices') return null;
    const u = decodeURIComponent(parts[1]);
    if (!u) return null;
    return u;
  }

  const udid = deepLinkUdid();
  if (!udid) return; // not deep-link mode; let the devices list (page/devices-list.js) run.
  window.__baguetteNativeMode = true;
  // One page for every device. What it shows follows the device: each
  // control only when the device has the ability it drives
  // (`deviceAbilities`, from /devices/<id>/device.json), and how it is
  // framed, described, badged and shared by its family's roles (`device`,
  // from `Families` — families/families.js, the one place that reads a
  // device's kind). Both are read at boot; the URL's tree decides neither.
  let device = null;
  let deviceAbilities = null;
  const can = (ability) => deviceAbilities === null || deviceAbilities.includes(ability);

  // --- State -------------------------------------------------------
  let session = null;
  let sim = null;           // Baguette SDK Simulator
  // The page's panels and their sheet rule (page/page-panels.js); made at boot.
  let panels = null;
  let axInspector = null;
  let pluginPanels = null;   // PluginPanels — manifest-declared plugin UI
  let render3DPanel = null;  // Sim3DPanel — live SceneKit stream + inspector
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
      for (const wrapper of root.querySelectorAll(':scope > div')) {
        wrapper.style.transform = 'rotate(' + rotationDegrees + 'deg)';
      }
    }
    handheldUIView().layoutHandheld();
  }

  // Set an orientation outright, no cycle step and no animation —
  // for a panel that arrives already turned (a foldable's unfolded
  // panel is landscape by the guest's choice; its cover is portrait).
  function snapOrientation(value) {
    const canonical = { 'portrait': 0, 'landscape-left': 90, 'portrait-upside-down': 180, 'landscape-right': 270 };
    currentOrientation = value;
    rotationDegrees = canonical[value] || 0;
    orientationIndex = Math.max(0, orientationCycle().indexOf(value));
    const root = document.getElementById('nativeDeviceFrame');
    if (!root) return;
    if (value === 'portrait') root.removeAttribute('data-orientation');
    else                      root.setAttribute('data-orientation', value);
    for (const wrapper of root.querySelectorAll(':scope > div')) {
      const t = wrapper.style.transition;
      wrapper.style.transition = 'none';
      wrapper.style.transform = 'rotate(' + rotationDegrees + 'deg)';
      void wrapper.offsetWidth;
      wrapper.style.transition = t;
    }
    handheldUIView().layoutHandheld();
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

    // 1. Load template + inline styles from page/device-page.html.
    const html = await fetchTemplate();
    if (!html) {
      document.body.innerHTML =
          '<pre style="color:#f87171;padding:24px;font-family:ui-monospace">page/device-page.html not found</pre>';
      return;
    }
    document.body.insertAdjacentHTML('beforeend', html);

    // 2. Resolve device name + iOS runtime from the list endpoint.
    //    The SDK definition gives us the bezel; /simulators.json gives
    //    us the human-readable identity that sits above it.
    const listing = await fetchDeviceListing(udid);
    if (listing) deviceAbilities = listing.abilities || [];
    device = window.Baguette._Families.device(listing, {
      id: udid,
      wire: {
        path: (id, suffix) => window.BaguetteTarget.path(id, suffix),
        listing: (id) => fetchDeviceListing(id),
        json: async (url) => (await fetch(url, { cache: 'no-store' })).json(),
        post: (url) => fetch(url, { method: 'POST' }),
        simulators: async () => {
          const r = await fetch('/simulators.json', { cache: 'no-store' });
          if (!r.ok) throw new Error(String(r.status));
          return r.json();
        },
      },
      storage: localStorage,
      address: location.search,
      reload: () => reloadPage(),
    });
    panels = window.Baguette._PagePanels.on({ element: (id) => document.getElementById(id) });
    const meta = await device.describe();
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
    // How it is framed is its family's: a simulator's own bezel, or the
    // chrome its user picked, riding `?chrome=` into the definition route.
    const deviceDefinitionURL = device.frame.definition;
    // A foldable is a book, and its book is Apple's own 3D model
    // (`V68.usdz`, the one Device Hub draws) posed by the hinge, with
    // both panels on its screens. Its main view is the live 3D stream
    // straight on, taps landing on whichever screen is lit, and the
    // flat chrome never shows for it while the guest is up — the cube
    // button turns the book instead of leaving 3D. The flat chrome
    // still carries the power card for a device that is not booted.
    const hinge = can('hinge') ? await readHinge() : null;
    foldable = !!(hinge && hinge.foldable);
    if (foldable) currentLitPanel = hinge.litPanel || 'primary';
    if (foldable && power().isBooted(meta.state)) {
      document.getElementById('nativeDeviceFrame').setAttribute('data-foldable', '');
    }
    try {
      sim = await useSimulator(deviceDefinitionURL);
      sim.mount(document.getElementById('nativeDeviceFrame'));
      // A pointer the page draws is its family's (a Mac display's).
      if (device.pointer) device.pointer.follow(sim);
    } catch (e) {
      console.warn('[native] no device definition:', (e && e.message) || e);
      sim = null;
      if (device.frame.chromePicker) {
        // No chrome picked yet (or the pick stopped resolving) — offer
        // the choices instead of a dead end. The stream needs the
        // SDK's canvas, so nothing else can start until a pick lands.
        await device.frame.chromePicker.show(document.getElementById('nativeDeviceFrame') || document.body);
        return;
      }
    }

    // 4. Companion-screens rail. Mounted before the stream opens, and
    //    regardless of whether the device is booted: "what other screens
    //    could I be looking at" is a question worth answering on a
    //    device that isn't running yet, and the rail's answer for a
    //    screen that isn't there is instructions rather than a pane.
    //    Also mounts first so it sits above the plugins rail in the
    //    shared right-edge stack.
    // Its other screens (CarPlay, the paired watch): its family's companions.
    if (can('displays') && device.companions) {
      companionsUI = device.companions.mount(companionsPort());
      companionsUI.mountScreensRail();
    }

    // 5. Settle the codec picker — it's on screen even when no session
    //    ever starts, so a shutdown device can't be left offering H.264.
    reflectFormat(currentFormat());

    // 6. Open stream — but only if there's a guest to stream. A
    //    shutdown device has no framebuffer, no HID, and no
    //    PurpleWorkspacePort; opening the socket would just paint
    //    black forever with no hint as to why. Show the power card on
    //    the device's own screen instead and start the stream once
    //    the user boots it (or once the boot already underway lands).
    if (sim && power().isBooted(meta.state)) {
      startMainView();
    } else {
      power().showPowerCard(sim ? meta.state : '');
    }

    wireActions();
    wireToolbarScroll();
    wireUnload();
    // A share's page follows its viewer: the Mac family's role.
    if (device.share) device.share.follow(pageBrowser());
    applyStoredTheme();

    // No flat screen to hand over (a foldable's main view is the 3D
    // book; no definition means no screen at all) — no Handheld button.
    if (foldable || !sim) {
      const handheldBtn = document.getElementById('nativeHandheldToggle');
      if (handheldBtn) handheldBtn.hidden = true;
    }
    // A Home Screen launch has a translucent status bar over the top of
    // the page (sim.html's meta) whatever mode it is in, so the view
    // always covers the whole glass and pads itself by the safe area
    // (`[data-standalone]` in page/device-page.html) — the workbench too.
    if (handheldUIView().launchedStandalone()) {
      document.getElementById('simNativeView').setAttribute('data-standalone', '');
      handheldUIView().coverViewport(true);
    }
    // Open in the hand when the address asks for it, or when the page
    // was launched from a Home Screen icon. No user gesture here, so no
    // browser fullscreen — a Home Screen launch has no bars to hide.
    if (handheldUIView().handheldWanted()) handheldUIView().enterHandheld({ fullscreen: false });

    // Capture surface — the output-size chip and the Record button.
    // Deliberately not awaited: the size vocabulary is four small files
    // and nothing on the stream path needs them, so the device paints
    // while they arrive.
    void capture().ensureCaptureModules().then(() => capture().mountCaptureUI());

    // Drag-and-drop: drop an .ipa/.app to install, or an image/video to
    // add to Photos. Dumb sender — POSTs the bytes to `/files`; the
    // Swift side routes by extension. The drop zone + highlight are
    // scoped to the device frame so the overlay traces the phone, not
    // the whole page. See docs/features/file-upload/README.md.
    if (window.SimFileDrop && (can('apps') || can('photos'))) {
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
    //
    // Not on an open foldable, though. iPhone Duo's unfolded panel is
    // landscape by the guest's own choice — SpringBoard turns it back
    // the moment the home screen shows — so forcing portrait would
    // leave the page fighting the device. The hinge poll says which
    // way the lit panel faces, and the page takes that instead.
    if (!foldable && power().isBooted(meta.state)) {
      resetToPortrait();
    }

    // Start watching for network conditioning immediately, before the card
    // has ever been opened. A throttle armed from the CLI in another
    // terminal is exactly the one someone forgets about, and this page is
    // where they will be looking when the app feels slow.
    // Panels that watch their device from the start (the network's armed dot).
    panels.watch(device);

  }

  // handheldView (page/internal/handheld-view.js), made on first use — after the modules have loaded — over
  // the page's port.
  let handheldUIViewUI = null;
  function handheldUIView() {
    return handheldUIViewUI || (handheldUIViewUI = window.Baguette._HandheldView.handheldView({
      get currentOrientation() { return currentOrientation; },
      get device() { return device; },
      get foldable() { return foldable; },
      get sim() { return sim; },
      refreshToolbarScroll: (...args) => refreshToolbarScroll(...args),
      toggle3D: (...args) => toggle3D(...args),
    }));
  }

  // One SDK simulator for a definition URL, wired to this page's
  // transport: the phone at boot, and a foldable's other panel when the
  // hinge brings it in.
  function useSimulator(definitionURL) {
    return window.Baguette.use({
      host: location.origin,
      udid,
      definitionURL,
      send: (payload) => {
        // A device that turns sends its input back in portrait (its family's orientation).
        const out = currentOrientation === 'portrait' || !device.orientation
          ? payload
          : device.orientation.toPortrait(payload, currentOrientation);
        const view = document.getElementById('simNativeView');
        if (view && view.getAttribute('data-render3d') === 'open' &&
            render3DPanel && render3DPanel.send(out)) return;
        if (session) session.send(out);
      },
      getOrientation: () => currentOrientation,
      log: (msg) => console.log('[native]', msg),
    });
  }

  async function readHinge() {
    try {
      const res = await fetch(`/devices/${encodeURIComponent(udid)}/hinge`);
      return res.ok ? await res.json() : null;
    } catch (e) { return null; }
  }

  /** iPhone Duo: two panels and a hinge. The page shows its book in
   *  3D — Apple's own model, posed by the hinge, both panels on its
   *  screens — so nothing here follows the hinge; the 3D scene does. */
  let foldable = false;
  let currentLitPanel = 'primary';

  function resetToPortrait() {
    if (!can('orientation')) return; // a physical phone rotates itself
    fetch(window.BaguetteTarget.path(udid, '/orientation?value=portrait'),
        { method: 'POST' }).catch(() => { /* best-effort */ });
  }

  // Theme toggle. Three logical states — "auto" (no manual pin,
  // follow OS via prefers-color-scheme), "light", "dark". The pill
  // in the bottom-right corner cycles light ↔ dark; we don't
  // expose "auto" from the click cycle because the icon set has
  // only two states. The user can reset to auto by deleting the
  // localStorage key in DevTools if needed.
  const THEME_KEY = 'baguette.simTheme';
  const FORMAT_KEY = 'asc.simFormat';

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
  // Same text-frame router as page/devices-stream.js: hand JSON envelopes to
  // the inspector first, then claim paste_result; anything nobody
  // claims falls through to the decoder's error logger.
  function routeStreamText(env) {
    if (env && env.type === 'hinge') return true;   // the 3D scene follows the hinge
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
  }

  function sessionCallbacks(onFirstPaint) {
    let painted = false;
    return {
      onSize: (w, h) => {
        lastPaintedSize = { w, h };
        // First frame after a boot — the guest is genuinely up, so
        // drop the power card and hand the screen back to the stream.
        power().hidePowerCard();
        if (!painted) { painted = true; if (onFirstPaint) onFirstPaint(); }
      },
      onFps:  (fps) => {
        const el = document.getElementById('nativeStatus');
        if (el) el.textContent = fps + ' fps';
      },
      onLog: (msg) => console.log('[native]', msg),
      onText: routeStreamText,
    };
  }

  function startSession(format) {
    // A recording samples the canvas this session paints into; a
    // restart (format swap, 3D close, device re-open) leaves it blank
    // for however long the new socket takes to land its first frame.
    if (session) capture().cancelRecording('stream restarted');
    if (session) { try { session.stop(); } catch (_) {} session = null; }
    // WebRTC is the phone plane only; a refused offer falls back to the
    // best socket format, as an undecodable one does below.
    const Session = format === 'webrtc' && window.WhepSession ? window.WhepSession : window.StreamSession;
    session = new Session(Object.assign({
      udid, format, version: 'v2',
      display: 'phone',
      canvas: sim.canvas,
      // `?congestion=remb|transport-cc|off` on the page picks how a WebRTC
      // viewer's bitrate follows the link (default: the server's choice).
      congestion: new URLSearchParams(location.search).get('congestion') || undefined,
      // `?codec=h264|h265|auto` on the page picks the codec (default: auto, H.265 when offered).
      codec: new URLSearchParams(location.search).get('codec') || undefined,
      onError: format === 'webrtc' ? () => {
        // A shared Mac's tab keeps its own choice: the socket from now on.
        const MacShare = sharedMac();
        if (MacShare) {
          try { sessionStorage.setItem(SHARE_FORMAT_KEY, MacShare.afterRefusal); } catch { /* the socket this once */ }
        } else {
          localStorage.removeItem(FORMAT_KEY);
        }
        startSession(MacShare ? window.StreamFormat.pick(MacShare.afterRefusal, decodeCapabilities()).id : currentFormat());
      } : undefined,
    }, sessionCallbacks()));
    // `boot()` runs this before wiring the toolbar and unload handler,
    // so a throw here killed the whole page, not just the canvas (#71).
    try {
      session.start();
    } catch (err) {
      console.warn('[native] ' + format + ' stream failed to start:',
          (err && err.message) || err);
      try { session.stop(); } catch (_) { /* ignore */ }
      session = null;
      if (format !== 'mjpeg') {
        localStorage.removeItem(FORMAT_KEY);
        startSession('mjpeg');
      }
      return;
    }
    // Companion panes are the user's standing choice, not this
    // session's — but their sockets don't survive a phone-session
    // restart's teardown, so reopen whichever are showing.
    if (companionsUI) companionsUI.resume(socketFormat());
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

  /// Both right-edge rails live in one stack so they can't overlap.
  /// Falls back to the view root if the template predates it.
  function rightRails() {
    return document.getElementById('nativeRightRails')
        || document.getElementById('simNativeView')
        || document.body;
  }

  // Its companion screens (CarPlay, the watch) — the Simulator family's
  // `companions` role, mounted at boot when the device has `displays`.
  let companionsUI = null;
  function companionsPort() {
    return {
      get udid() { return udid; },
      socketFormat: (...args) => socketFormat(...args),
      refreshToolbarScroll: (...args) => refreshToolbarScroll(...args),
      rightRails: (...args) => rightRails(...args),
    };
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

  // powerCard (page/internal/power-card.js), made on first use — after the modules have loaded — over
  // the page's port.
  let powerUI = null;
  function power() {
    return powerUI || (powerUI = window.Baguette._PowerCard.powerCard({
      get device() { return device; },
      get deviceName() { return deviceName; },
      get sim() { return sim; },
      get foldable() { return foldable; },
      startMainView: (...args) => startMainView(...args),
      resetToPortrait: (...args) => resetToPortrait(...args),
    }));
  }

  function startMainView() {
    if (foldable) {
      const frame = document.getElementById('nativeDeviceFrame');
      if (frame) frame.setAttribute('data-foldable', '');
      toggle3D({ fixed: true });
      // The unfolded panel is landscape-left by the guest's choice and
      // the cover portrait; the rotate button cycles from there.
      const start = currentLitPanel === 'secondary' ? 'landscape-left' : 'portrait';
      currentOrientation = start;
      orientationIndex = Math.max(0, orientationCycle().indexOf(start));
      return;
    }
    startSession(currentFormat());
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

  // Which pill is lit, and which isn't offerable at all.
  function reflectFormat(format) {
    const caps = decodeCapabilities();
    document.querySelectorAll('#nativeFormatPicker .fmt-btn').forEach((b) => {
      b.classList.toggle('active', b.dataset.v === format);
      const fmt = window.StreamFormat && window.StreamFormat.named(b.dataset.v);
      const playable = !fmt || fmt.isPlayable(caps);
      if (b.dataset.titleDefault == null) {
        b.dataset.titleDefault = b.getAttribute('title') || '';
      }
      b.disabled = !playable;
      b.title = playable ? b.dataset.titleDefault : fmt.whyUnplayable;
    });
  }

  // --- Helpers -----------------------------------------------------
  let _templatePromise = null;
  function fetchTemplate() {
    if (_templatePromise) return _templatePromise;
    _templatePromise = fetch('/page/device-page.html')
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

  /** The device as the server lists it — kind and abilities — or null. */
  async function fetchDeviceListing(targetUdid) {
    try {
      const r = await fetch(window.BaguetteTarget.path(targetUdid, '/device.json'), { cache: 'no-store' });
      return r.ok ? await r.json() : null;
    } catch (_) {
      return null;
    }
  }

  // The format every surface in this page streams at — phone, CarPlay,
  // watch and the 3D panel alike. Companions used to be pinned to MJPEG
  // independently of the phone, which meant a session the user had set to
  // H.264 still carried uncapped full JPEGs on its companion sockets.
  //
  // `StreamFormat` filters the stored value against what this browser
  // can decode, so nothing unplayable reaches the socket.
  /// The format asked for: a shared Mac's tab picks its own, WebRTC until it
  /// does, leaving the saved choice for every other device alone.
  const SHARE_FORMAT_KEY = 'asc.shareFormat';
  function sharedMac() {
    return device && device.share ? window.Baguette._MacShare : null;
  }
  /** Reload this page — on a shared Mac's, keeping its share. */
  function reloadPage() {
    const MacShare = sharedMac();
    if (MacShare) MacShare.reloadKeepingShare(location); else location.reload();
  }

  function storedFormat() {
    const MacShare = sharedMac();
    if (!MacShare) return localStorage.getItem(FORMAT_KEY);
    let picked = null;
    try { picked = sessionStorage.getItem(SHARE_FORMAT_KEY); } catch { /* none picked */ }
    return MacShare.format(picked);
  }

  function currentFormat() {
    if (!window.StreamFormat) return 'mjpeg';
    return window.StreamFormat
        .pick(storedFormat(), decodeCapabilities()).id;
  }

  /** What a surface that only has a stream socket — CarPlay, the watch,
   *  the 3D panel — streams at: the page's format, or for WebRTC the best
   *  socket format. */
  function socketFormat() {
    if (!window.StreamFormat) return 'mjpeg';
    return window.StreamFormat
        .pick(storedFormat(), decodeCapabilities())
        .forSockets(decodeCapabilities()).id;
  }

  /** What this browser can play, as `StreamFormat` wants to be told it. */
  function decodeCapabilities() {
    return {
      hardwareDecoder: !!(window.FrameDecoder
          && window.FrameDecoder.isHardwareAvailable()),
      webrtc: typeof window.RTCPeerConnection === 'function' && !!window.WhepSession,
    };
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

  // ── Toolbar ──────────────────────────────────────────────────────
  // The toolbar's clusters and fold menus (page/internal/toolbar-view.js), made on
  // first use — after the modules have loaded — over the page's port.
  let toolbarUI = null;
  function toolbar() {
    return toolbarUI || (toolbarUI = window.Baguette._ToolbarView.toolbarView({
      get abilities() { return deviceAbilities; },
    }));
  }

  /// A device that isn't a simulator has a badge saying what it can do, from the abilities
  /// the server lists for it. The controls themselves already follow
  /// those abilities (`buildToolbarClusters`), for every device.
  function applyDeviceModeChrome() {
    if (!device.badge) return;
    const osEl = document.getElementById('nativeDeviceOS');
    if (osEl && !document.getElementById('nativeDeviceBadge')) {
      const badge = document.createElement('span');
      badge.id = 'nativeDeviceBadge';
      const words = window.Baguette._DeviceBadge.of(deviceAbilities || []);
      badge.textContent = words.text;
      badge.title = words.title;
      badge.style.cssText =
        'margin-left:8px;padding:2px 8px;border:1px solid #fde68a;' +
        'border-radius:99px;background:#fef3c7;color:#92400e;' +
        'font-size:10.5px;font-weight:700;letter-spacing:.03em;white-space:nowrap';
      osEl.insertAdjacentElement('afterend', badge);
    }
    if (device.frame.picker) device.frame.picker.mount(document.getElementById('nativeDeviceBadge'));
  }

  /**
   * Start the floating panels (status bar, network, defaults, …) below
   * the toolbar wherever it actually is.
   *
   * The toolbar rides the device's vertically centred column, so a
   * window taller than the device needs pushes it down past the panels'
   * old fixed `top: 84px` and the bar covered each panel's first row.
   * Watching the view as well as the bar catches a window resize that
   * re-centres the column without changing the bar's own size.
   */
  function placeFloatingPanels() {
    const view = document.getElementById('simNativeView');
    const bar = document.querySelector('#simNativeView .top-bar');
    if (!view || !bar || typeof ResizeObserver === 'undefined') return;
    const place = () => {
      const below = Math.round(bar.getBoundingClientRect().bottom) + 24;
      view.style.setProperty('--nv-panel-top', Math.max(84, below) + 'px');
    };
    const observer = new ResizeObserver(place);
    observer.observe(view);
    observer.observe(bar);
    // The device frame settling (bezel image, rotation) moves the bar
    // without resizing either element.
    const frame = document.getElementById('nativeDeviceFrame');
    if (frame) observer.observe(frame);
    place();
  }

  function wireToolbarScroll() {
    if (!toolbar().buildToolbarClusters()) return;
    applyDeviceModeChrome();

    document.addEventListener('click', (event) => {
      const btn = event.target.closest('#simNativeView .tb-fold-btn');
      if (btn) {
        const pop = btn.parentElement.querySelector('.tb-fold-pop');
        const open = btn.getAttribute('aria-expanded') === 'true';
        toolbar().closeFoldMenus();
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
      if (!event.target.closest('#simNativeView .tb-fold')) toolbar().closeFoldMenus();
    });

    const layoutToolbar = () => toolbar().layoutToolbar();
    refreshToolbarScroll = layoutToolbar;
    window.addEventListener('resize', layoutToolbar);
    placeFloatingPanels();
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
    window.__nativeScreenshot = () => capture().downloadSnapshot();
    // Record is Screenshot's moving-picture sibling: same source, same
    // picked size, one toggle instead of a one-shot.
    window.__nativeRecord = () => { void capture().toggleRecording(); };
    window.__nativeClearRecordings = () => capture().clearRecordings();
    window.__nativeHideRecordings = () => capture().hideRecordings();
    window.__nativeClose = () => {
      // Shutting the window from inside a popup-style URL: try
      // window.close (only works for script-opened tabs) then fall
      // back to navigating to the list.
      try { window.close(); } catch (_) { /* ignore */ }
      if (!window.closed) location.href = '/simulators';
    };
    window.__nativeSetFormat = (next) => {
      // Storing an undecodable format wedges the origin (#71). The
      // button is already disabled; this is the second lock.
      const wanted = window.StreamFormat && window.StreamFormat.named(next);
      if (!wanted || !wanted.isPlayable(decodeCapabilities())) return;
      const current = currentFormat();
      const view = document.getElementById('simNativeView');
      if (current === wanted.id && (session ||
          (view && view.getAttribute('data-render3d') === 'open'))) return;
      if (sharedMac()) {
        try { sessionStorage.setItem(SHARE_FORMAT_KEY, wanted.id); } catch { /* the tab forgets */ }
      } else {
        localStorage.setItem(FORMAT_KEY, wanted.id);
      }
      reflectFormat(wanted.id);
      if (view && view.getAttribute('data-render3d') === 'open') {
        if (render3DPanel) render3DPanel.setFormat(wanted.forSockets(decodeCapabilities()).id);
      } else {
        startSession(wanted.id);
      }
    };
    window.__nativeToggleTheme = () => {
      setTheme(currentTheme() === 'light' ? 'dark' : 'light');
    };
    window.__nativeToggleLogs = () => panels.toggle('logs', device);
    window.__nativeToggleCamera = () => panels.toggle('camera', device);
    window.__nativeToggleStatusBar = () => panels.toggle('statusBar', device);
    window.__nativeToggleLocation = () => panels.toggle('location', device);
    window.__nativeToggleNetwork = () => panels.toggle('network', device);
    window.__nativeToggleDefaults = () => panels.toggle('defaults', device);
    window.__nativeToggleNotify = () => panels.toggle('notify', device);
    window.__nativeToggle3D = () => toggle3D();
    window.__nativeEnterHandheld = () => handheldUIView().enterHandheld();
    window.__nativeHandheldMenu = (open) => handheldUIView().setHandheldMenu(!!open);
    window.__nativeHandheldHintClose = () => handheldUIView().hideHomeScreenHint();
    window.__nativeHandheldAction = (action) => {
      handheldUIView().setHandheldMenu(false);
      if (action === 'exit') handheldUIView().exitHandheld();
      else if (action === 'rotate') window.__nativeRotate();
      else if (sim) sim.pressButton(action);
    };
    window.__nativeToggle3DInspector = () => toggle3DInspector();
    // The watch's hardware buttons. Same `button` envelope the phone's
    // bezel buttons use, but down the watch's own socket — the press
    // has to reach the watch's HID, not the phone we happen to be
    // looking at beside it. Silently no-ops when the pane is closed;
    // there is no button row on screen to press in that case.
    window.__nativeWatchButton = (name) => {
      if (companionsUI) companionsUI.pressWatch(name);
    };
    window.__nativeToggleAx = () => {
      if (!axInspector) return;
      if (axInspector.isEnabled()) axInspector.disable();
      else axInspector.enable();
    };
    // Sidebar-view jump — bounce out of focus mode and into the
    // inline `startStream` layout on `/simulators`. The hash is
    // the cue page/devices-stream.js reads on load to auto-open the same
    // device's stream view without an extra click.
    window.__nativeOpenSidebarView = () => {
      location.href = '/simulators#stream=' + encodeURIComponent(udid);
    };

    // Orientation cycle — one click advances 90° CW. Cycle length
    // varies by device class: 3 on iPhone (skips upside-down,
    // which iPhone UIKit ignores), 4 on iPad. POSTs the new value
    // through the `/devices/<udid>/orientation?value=...` route;
    // server delegates to `simulator.orientation().set(...)`, which
    // dispatches a device orientation change through the appropriate backend.
    window.__nativeRotate = () => {
      const cycle = orientationCycle();
      orientationIndex = (orientationIndex + 1) % cycle.length;
      const value = cycle[orientationIndex];
      // A foldable's book turns in 3D, as the flat chrome would.
      if (foldable) {
        currentOrientation = value;
        if (render3DPanel) render3DPanel.setInterfaceOrientation(value);
        const url = '/devices/' + encodeURIComponent(udid)
            + '/orientation?value=' + encodeURIComponent(value);
        fetch(url, { method: 'POST' }).catch(() => { /* best-effort */ });
        return;
      }
      // Mirror the rotation in the UI immediately. The CSS
      // transform on `#nativeDeviceFrame > div` rotates the bezel
      // + canvas as one unit, while the input + overlay wrappers
      // remap coords back to portrait so taps still land on the
      // iOS element under the cursor.
      applyOrientation(value);
      const url = '/devices/' + encodeURIComponent(udid)
          + '/orientation?value=' + encodeURIComponent(value);
      fetch(url, { method: 'POST' }).catch(() => { /* best-effort */ });
    };

    // Shake — fires a UIKit motionShake on the frontmost app
    // (shake-to-undo etc). POSTs to `/devices/<udid>/shake`; the
    // server delegates to `simulator.shake().shake()`, backed by
    // `simctl spawn notifyutil`. Unlike rotate there's no visual state
    // to mirror — the motion event lives entirely in the guest — so
    // this is a pure fire-and-forget POST.
    window.__nativeShake = () => {
      const url = '/devices/' + encodeURIComponent(udid) + '/shake';
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

  // Live 3D is a main-view mode, not a duplicate preview. Its WebSocket
  // replaces the 2D StreamSession while open and carries both MJPEG
  // frames and the same inbound input/control envelopes.
  function toggle3D(opts) {
    const view = document.getElementById('simNativeView');
    const host = document.getElementById('native3DHost');
    const stage = document.getElementById('native3DStage');
    const btn = document.getElementById('native3DToggle');
    const open = view && view.getAttribute('data-render3d') === 'open';
    if (!view || !host || !stage || !sim) return;
    const fixed = !!(opts && opts.fixed);
    // A foldable lives in 3D: the cube turns the book, or sets it back
    // straight, rather than leaving for the flat stream.
    if (open && foldable && render3DPanel && !fixed) {
      render3DPanel.setFixed(!render3DPanel.fixed);
      if (btn) btn.classList.toggle('active', !render3DPanel.fixed);
      const inspector = !render3DPanel.fixed && localStorage.getItem('asc.3dInspector') !== 'closed';
      if (inspector) view.setAttribute('data-render3d-inspector', 'open');
      else view.removeAttribute('data-render3d-inspector');
      const sheet = document.getElementById('native3DSheet');
      if (sheet) sheet.setAttribute('aria-hidden', inspector ? 'false' : 'true');
      return;
    }
    // The canvas being recorded is about to be swapped for the other
    // mode's, and the two are different surfaces at different sizes.
    capture().cancelRecording('switched between 2D and 3D');
    // `open` is the state we're LEAVING, so it doubles as "will be 2D".
    capture().reflect3DCaptureControls(open);
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
      const inspectorOpen = !fixed && localStorage.getItem('asc.3dInspector') !== 'closed';
      if (inspectorOpen) {
        view.setAttribute('data-render3d-inspector', 'open');
      }
      const sheet = document.getElementById('native3DSheet');
      if (sheet) sheet.setAttribute('aria-hidden', inspectorOpen ? 'false' : 'true');
      if (btn) btn.classList.toggle('active', !fixed);
      const status = document.getElementById('nativeStatus');
      if (status) status.textContent = '3D live';
      // Told BEFORE the stream starts: a picked size raises the
      // stream's pixel budget (Sim3DPanel.streamBudget), so setting it
      // afterwards would open at the ordinary budget and restart.
      if (render3DPanel && typeof render3DPanel.setCaptureSettings === 'function') {
        render3DPanel.setCaptureSettings(capture().captureSettings());
      }
      if (!render3DPanel && window.Sim3DPanel && udid) {
        render3DPanel = new window.Sim3DPanel();
        render3DPanel.setCaptureSettings(capture().captureSettings());
        render3DPanel.attach(host, stage, udid, {
          deviceSize: { width: sim.screen.size.width, height: sim.screen.size.height },
          format: socketFormat(),
          background: live3DBackground(),
          fixed,
          onFps: (fps) => {
            const status = document.getElementById('nativeStatus');
            if (status) status.textContent = fps + ' fps · 3D';
          },
        });
      } else if (render3DPanel) {
        render3DPanel.background = live3DBackground();
        if (render3DPanel.fixed !== fixed) render3DPanel.setFixed(fixed, { silent: true });
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

  /// The page as a share's follow sees it (families/mac/internal/share-follow.js).
  function pageBrowser() {
    return {
      get width() { return window.innerWidth; },
      get height() { return window.innerHeight; },
      get devicePixelRatio() { return window.devicePixelRatio; },
      userAgent: navigator.userAgent,
      location,
      fetch: (url, init) => fetch(url, init),
      on: (event, fn) => window.addEventListener(event, fn),
      setTimeout: (fn, ms) => setTimeout(fn, ms),
      clearTimeout: (t) => clearTimeout(t),
    };
  }

  function wireUnload() {
    window.addEventListener('beforeunload', () => {
      try { power().hidePowerCard(); } catch (_) { /* ignore */ }
      try { capture().cancelRecording('page unloading'); } catch (_) { /* ignore */ }
      try { capture().clearRecordings(); } catch (_) { /* ignore */ }
      try { if (session) session.stop(); } catch (_) { /* ignore */ }
      try { if (companionsUI) companionsUI.detach(); } catch (_) { /* ignore */ }
      try { if (sim) sim.detach(); } catch (_) { /* ignore */ }
      try { if (axInspector) axInspector.detach(); } catch (_) { /* ignore */ }
      try { panels.detach(); } catch (_) { /* ignore */ }
      try { if (render3DPanel) render3DPanel.detach(); } catch (_) { /* ignore */ }
    });
  }

  // --- Capture ------------------------------------------------------
  // The capture controls (capture/capture-controls.js), made on first use —
  // after the modules have loaded — over the page's port.
  let captureUI = null;
  function capture() {
    return captureUI || (captureUI = window.Baguette._CaptureControls.captureControls({
      can: (ability) => can(ability),
      get device() { return device; },
      get deviceName() { return deviceName; },
      get session() { return session; },
      get sim() { return sim; },
      get render3DPanel() { return render3DPanel; },
      toggle3D: (opts) => toggle3D(opts),
      refreshToolbarScroll: () => refreshToolbarScroll(),
    }));
  }

  console.log('[Baguette] page/device-page.js active for', udid);
})();
