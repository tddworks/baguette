// The capture controls of the device page: the output-size chip, the
// screenshot, and recording — of whatever the view shows (the live screen,
// or the 3D stage). What it needs of the page is its port:
//
//   { can(ability), device, deviceName, session, sim, render3DPanel,
//     toggle3D(opts), refreshToolbarScroll() }
//
// Out of page/device-page.js (docs/features/web-page/design.md §4, capture/).

export function captureControls(page) {
  // --- Capture: one picked size, two verbs, two modes ---------------
  //
  // "App Store 6.9″" / "Square" / "16:9" is chosen once, on the chip in
  // the toolbar, and every capture on this page reads it — in 2D and in
  // 3D alike. The vocabulary is shared with the HTTP routes and the CLI
  // and lives in Resources/Web/capture/; see
  // docs/features/capture-size/README.md. Nothing here reimplements any of it.
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
  // ones inside page/device-page.html. Anything already on the page (sim.html
  // loads /recorder.js today) is left alone — the guard is the global
  // the module hangs itself on, not the URL, so this stays correct
  // whichever page happens to have loaded it first.
  const CAPTURE_MODULES = [
    ['/capture/capture-size.js', () => window.Baguette && window.Baguette._CaptureSize],
    ['/capture/capture-settings.js', () => window.Baguette && window.Baguette._CaptureSettings],
    ['/capture/capture-composer.js', () => window.Baguette && window.Baguette._CaptureComposer],
    ['/capture/capture-size-menu.js', () => window.CaptureSizeMenu],
    ['/capture/recorder.js', () => window.BrowserRecorder],
  ];

  let captureMenu = null;   // CaptureSizeMenu — the size chip in the toolbar

  // Recording state, mirroring page/devices-stream.js's `recordingState`:
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
    // The menu reads the size and settings vocabulary as it's made: all three, or no menu.
    const B = window.Baguette || {};
    if (host && window.CaptureSizeMenu && B._CaptureSettings && B._CaptureSize && !captureMenu) {
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
          page.refreshToolbarScroll();
          // The 3D render is produced server-side, so the size has to
          // travel with the request rather than being applied to a
          // canvas we hold.
          if (page.render3DPanel && typeof page.render3DPanel.setCaptureSettings === 'function') {
            page.render3DPanel.setCaptureSettings(settings);
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
    page.refreshToolbarScroll();
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
      const canvas = page.render3DPanel && page.render3DPanel.canvas;
      // `data-painted` is Sim3DPanel's own "a frame has landed" flag;
      // without it the canvas is a blank allocation.
      if (!canvas || !canvas.width || !canvas.hasAttribute('data-painted')) return null;
      return {
        canvas, frameImg: null, screen: null, overlayHost: null, mode: '3d',
      };
    }
    if (!page.sim || !page.sim.canvas || !page.sim.canvas.width) return null;
    const settings = captureSettings();
    const withFrame = settings ? settings.withFrame : false;
    return {
      canvas: page.sim.canvas,
      frameImg: withFrame && page.sim._bezel ? page.sim._bezel.frameImg : null,
      screen: withFrame ? page.sim.screen.def : null,
      overlayHost: page.sim.pinchOverlayContainer,
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
    if (is3DOpen() && page.render3DPanel && typeof page.render3DPanel.download === 'function') {
      if (typeof page.render3DPanel.setCaptureSettings === 'function') {
        page.render3DPanel.setCaptureSettings(captureSettings());
      }
      page.render3DPanel.download();
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
    if (was !== recordingState.active) page.refreshToolbarScroll();
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
    return (page.deviceName || 'simulator').replace(/[^A-Za-z0-9._-]/g, '_');
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

  return { ensureCaptureModules, mountCaptureUI, reflect3DCaptureControls, captureSettings, downloadSnapshot, toggleRecording, cancelRecording, clearRecordings, hideRecordings };
}

if (typeof window !== 'undefined') {
  window.Baguette = window.Baguette || {};
  window.Baguette._CaptureControls = { captureControls };
}
