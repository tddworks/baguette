// Stream orchestrator. Wires the four single-responsibility modules
// on Stream click and exposes the sidebar callbacks the stream view
// invokes via inline `onclick`:
//
//   FrameDecoder    — WS bytes → paintable frame      (frame-decoder.js)
//   DeviceFrame     — bezel + screen DOM              (device-frame.js)
//   StreamSession   — WS + paint loop                 (stream-session.js)
//   CaptureGallery  — screenshot fetch + thumbs       (capture-gallery.js)
//   SimInput / MouseGestureSource / PinchOverlay      (sim-input.js)
//
// This file owns nothing besides the lifecycle (start / stop) and
// the sidebar callbacks. Adding a new format / new device shape /
// new capture mode lands in its dedicated module; this file rarely
// changes.
(function () {
  'use strict';

  // --- Live stream state ---
  let session = null;       // StreamSession
  let sim = null;           // Baguette SDK Simulator (replaces DeviceFrame + SimInput + MouseGestureSource + BezelButtons)
  let gallery = null;       // CaptureGallery
  let logPanel = null;
  let axInspector = null;   // AXInspector — accessibility-tree overlay
  let cameraPanel = null;   // CameraPanel — Mac webcam → /tmp/SimCam.bgra

  let activeUdid = null;
  let activeName = null;
  let sizeMenu = null;      // CaptureSizeMenu — output size / fit / bezel
  let captureWithFrame = false;
  let lastPaintedSize = { w: 0, h: 0 };

  // One persisted selection for both capture surfaces in this sidebar —
  // a screenshot and a recording of the same device should come out the
  // same shape without asking twice.
  const CAPTURE_STORAGE_KEY = 'asc.capture.stream';

  // Shared with the focus view (sim-native.js) — one stream-format
  // preference per origin, whichever surface set it.
  const FORMAT_KEY = 'asc.simFormat';

  // Recording state. BrowserRecorder spins up a compose canvas only
  // while active; references are pulled from what's already on the
  // page (frameImg from the SDK bezel, screen geometry from
  // sim.screen.def, pinch dots from PinchOverlay's DOM container).
  // Idle cost: zero.
  //   state.recorder      : BrowserRecorder instance during a recording
  //   state.savedQuality  : pre-recording stream config; restored on stop
  //   state.active        : true between start() and stop()
  //   state.startedAt     : ms timestamp for the live timer
  //   state.timer         : interval handle that ticks the toolbar label
  //   state.entries       : finished recordings (download links)
  const recordingState = {
    recorder: null, savedQuality: null,
    active: false, startedAt: 0, timer: null,
    entries: [],
  };

  // Picks the currently selected `simQ` knob for one of scale / fps /
  // bps so we can restore it after recording. Reads the active button
  // class instead of a separate state slot — single source of truth.
  function readActiveQuality() {
    const pick = (k) => {
      const btn = document.querySelector(
        `#simStreamSidebar .simQ[data-k="${k}"].btn-primary`
      );
      return btn ? parseInt(btn.dataset.v, 10) : null;
    };
    return { scale: pick('scale'), fps: pick('fps'), bps: pick('bps') };
  }

  // Apply scale / fps / bitrate to the active stream + reflect the
  // selection on the sidebar buttons. Mirrors what `_simSetQuality`
  // does on a click, but driven by recording lifecycle.
  function applyQuality({ scale, fps, bps }) {
    if (!session) return;
    if (scale != null) session.send({ type: 'set_scale',   scale });
    if (fps   != null) session.send({ type: 'set_fps',     fps   });
    if (bps   != null) session.send({ type: 'set_bitrate', bps   });
    const reflect = (k, v) => {
      if (v == null) return;
      document.querySelectorAll(`#simStreamSidebar .simQ[data-k="${k}"]`)
        .forEach((b) => b.classList.toggle('btn-primary', parseInt(b.dataset.v, 10) === v));
    };
    reflect('scale', scale);
    reflect('fps',   fps);
    reflect('bps',   bps);
  }

  // --- Helpers ---
  const escapeHTML = window.escapeHTML || ((s) => String(s).replace(/[&<>"']/g,
    (c) => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c])));

  function log(msg, isErr) {
    const el = document.getElementById('simActivityLog');
    if (!el) return;
    const t = new Date().toLocaleTimeString('en-US', {
      hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit',
    });
    const entry = document.createElement('div');
    entry.style.cssText = 'padding:2px 0;border-bottom:1px solid var(--border-light,rgba(0,0,0,0.05))';
    entry.innerHTML =
      `<span style="color:var(--text-muted);margin-right:6px">${t}</span>` +
      `<span style="color:var(--${isErr ? 'danger' : 'success'})">${escapeHTML(msg)}</span>`;
    if (el.children.length === 1 && !el.children[0].querySelector('span')) el.innerHTML = '';
    el.appendChild(entry);
    el.scrollTop = el.scrollHeight;
  }

  // Stream view template — inner of #simPluginView from sim-stream.html
  // plus its head <style> blocks (which sim.html doesn't carry).
  let _templatePromise = null;
  async function streamViewHTML() {
    if (!_templatePromise) {
      // Absolute path: a relative `sim-stream.html` resolves against
      // the current URL, so when the page is loaded directly at
      // `/simulators/<udid>` it would request
      // `/simulators/sim-stream.html` — which the `/simulators/:udid`
      // route happily answers with sim.html. The parser then can't
      // find `#simPluginView` and downstream `getElementById` calls
      // (`simStreamTitle`, etc.) start returning null.
      _templatePromise = fetch('/sim-stream.html')
        .then((r) => r.text())
        .then((html) => {
          const doc = new DOMParser().parseFromString(html, 'text/html');
          const styles = Array.from(doc.head.querySelectorAll('style'))
            .map((s) => s.outerHTML).join('\n');
          const root = doc.getElementById('simPluginView');
          return styles + (root ? root.innerHTML : '');
        })
        .catch(() => '');
    }
    return _templatePromise;
  }

  // Same filtered pick the focus view makes — see stream-format.js.
  function pickFormat() {
    if (!window.StreamFormat) return 'mjpeg';
    return window.StreamFormat
        .pick(localStorage.getItem(FORMAT_KEY), decodeCapabilities()).id;
  }

  /** What this browser can play, as `StreamFormat` wants to be told it. */
  function decodeCapabilities() {
    return {
      hardwareDecoder: !!(window.FrameDecoder
          && window.FrameDecoder.isHardwareAvailable()),
    };
  }

  /** Lights the running format; disables codecs with no decoder here. */
  function reflectFormatPicker(format) {
    const caps = decodeCapabilities();
    document.querySelectorAll('#simFormatRow .simFmt').forEach((b) => {
      b.classList.toggle('btn-primary', b.dataset.v === format);
      const fmt = window.StreamFormat && window.StreamFormat.named(b.dataset.v);
      const playable = !fmt || fmt.isPlayable(caps);
      b.disabled = !playable;
      if (!playable) {
        b.title = fmt.label + ' needs WebCodecs, which browsers only expose '
            + 'on a secure origin. Open this page over HTTPS or on localhost.';
      }
    });
  }

  // --- Lifecycle ---

  async function startStream(udid, name) {
    activeUdid = udid;
    activeName = name;

    document.getElementById('simListView').style.display = 'none';
    const view = document.getElementById('simPluginView');
    view.innerHTML = await streamViewHTML();
    view.style.display = '';
    document.getElementById('simStreamTitle').textContent = name;

    // Boot the SDK: the page hands it a `send` closure that defers
    // to the StreamSession's WebSocket. Pre-open gestures (rare —
    // the user can't interact until the page renders) get dropped.
    sim = await window.Baguette.use({
      host: location.origin,
      udid,
      send: (payload) => { if (session) session.send(payload); },
      log,
    });
    sim.mount(document.getElementById('simDeviceFrame'));

    // Text-frame router. The stream WS carries binary video frames
    // and JSON envelopes (describe_ui_result, paste_result, server
    // pushes). The accessibility inspector consumes
    // describe_ui_result; anything nobody claims falls through to
    // the decoder's error logger.
    const onStreamText = (env) => {
      if (axInspector && axInspector.handleEnvelope(env)) return true;
      if (env && env.type === 'paste_result') {
        if (!env.ok) log('Paste failed: ' + (env.error || 'unknown'), true);
        return true;
      }
      if (env && env.type === 'copy_result') {
        log(env.ok ? 'Copied sim pasteboard to host clipboard'
                   : 'Copy failed: ' + (env.error || 'unknown'), !env.ok);
        return true;
      }
      return false;
    };

    // False when the decoder wouldn't construct; `session` stays null.
    const openSession = (fmt) => {
      session = new window.StreamSession({
        udid, format: fmt, version: 'v2',
        canvas: sim.canvas,
        onSize: (w, h) => {
          const changed = w !== lastPaintedSize.w || h !== lastPaintedSize.h;
          lastPaintedSize = { w, h };
          // Ratio presets resolve against the source, so the hint moves
          // when the stream scale does.
          if (changed) renderCaptureSizeHint();
        },
        onFps:  (fps) => {
          const el = document.getElementById('simStreamFps');
          if (el) el.textContent = fps + ' fps';
        },
        onLog: log,
        onText: onStreamText,
      });
      try {
        session.start();
        return true;
      } catch (err) {
        log(`${fmt.toUpperCase()} stream failed to start: `
            + `${(err && err.message) || err}`, true);
        try { session.stop(); } catch { /* ignore */ }
        session = null;
        return false;
      }
    };

    // A preference the decoder can't honour: drop it, retry on MJPEG (#71).
    let format = pickFormat();
    if (!openSession(format) && format !== 'mjpeg') {
      localStorage.removeItem(FORMAT_KEY);
      format = 'mjpeg';
      openSession(format);
    }
    log(`Stream: ${format.toUpperCase()}${format === 'avcc' ? ' (hw-decoded)' : ''}`);
    // After the attempt — `format` may have fallen back.
    requestAnimationFrame(() => reflectFormatPicker(format));

    gallery = new window.CaptureGallery({
      udid, screen: sim.screen.def, frameImg: sim._bezel.frameImg,
    });
    gallery.clear();
    renderGallery();
    mountCaptureSizeMenu();

    // Live unified-log panel — opens its own WS to /simulators/<udid>/logs.
    // Independent of the stream socket so logs survive even when the
    // user pauses the frame stream, and vice-versa.
    const logHost = document.getElementById('simLogPanel');
    if (logHost && window.LogPanel) {
      logHost.innerHTML = '';
      logPanel = new window.LogPanel(logHost, { udid, level: 'info' });
    }

    // Accessibility inspector — toggle in sidebar, overlay over the
    // screen. Shares the stream WS for `describe_ui` round-trips; on
    // every fresh hover (mouseenter) it fetches a new tree, so the
    // user always inspects current state without paying for polling.
    const axHost = document.getElementById('simAxInspector');
    if (axHost && window.AXInspector) {
      axHost.innerHTML = '';
      axInspector = new window.AXInspector({
        host: axHost,
        screenArea: sim.screenArea,
        send: (payload) => session && session.send(payload),
        // AX inspector still uses the legacy `{w, h}` shape; the SDK
        // Screen exposes `{width, height}`. Adapt at the boundary
        // until the inspector itself moves to the SDK shape.
        getDeviceSize: () => ({ w: sim.screen.size.width, h: sim.screen.size.height }),
      });
    }

    // Camera control card — opens its own WS to
    // /simulators/<udid>/camera and pumps Mac webcam frames into the
    // shared-memory buffer the VirtualCamera dylib reads. Independent
    // of the stream socket and the logs socket — closing the page
    // tears all three down.
    const cameraHost = document.getElementById('simCameraPanel');
    if (cameraHost && window.CameraPanel) {
      cameraHost.innerHTML = '';
      cameraPanel = new window.CameraPanel();
      cameraPanel.attach(cameraHost, udid);
    }
  }

  function stopStream() {
    if (recordingState.recorder) {
      try { recordingState.recorder.cancel(); } catch { /* ignore */ }
    }
    if (sizeMenu) { sizeMenu.detach(); sizeMenu = null; }
    if (axInspector) { axInspector.detach(); axInspector = null; }
    if (cameraPanel) { cameraPanel.detach(); cameraPanel = null; }
    if (session) { session.stop(); session = null; }
    if (sim) { sim.detach(); sim = null; }
    if (logPanel) { logPanel.detach(); logPanel = null; }
    gallery = null;
    activeUdid = null;
    activeName = null;
    resetRecordingUI();

    const view = document.getElementById('simPluginView');
    if (view) { view.style.display = 'none'; view.innerHTML = ''; }
    const list = document.getElementById('simListView');
    if (list) list.style.display = '';
    if (window.loadSimDeviceList) window.loadSimDeviceList();
  }

  // --- Capture size ---------------------------------------------------
  // The sidebar's screenshot and its recording share one CaptureSettings,
  // edited through the CaptureSizeMenu chip in the Captures card header.

  /** The current selection, or null when /capture/*.js isn't loaded
   *  (the host SPA can pull in sim-stream.js on its own). Call sites
   *  treat null as "no resizing", i.e. exactly the old behaviour. */
  function captureSettings() {
    return sizeMenu ? sizeMenu.settings : null;
  }

  /**
   * What a ratio preset resolves against.
   *
   * With the bezel composited in, the output is bezel-sized — both
   * surfaces draw the source into the frame image's natural box.
   *
   * Bare, it's the device's *native* pixel size, not `lastPaintedSize`:
   * `/screenshot.jpg` is always served at native resolution regardless
   * of the stream's Resolution knob, and the recorder ratchets the
   * stream to scale 1 before it starts. `lastPaintedSize` is the
   * decoded frame, i.e. native divided by that knob — so multiply it
   * back out rather than resolving a `square` against a third of the
   * device.
   *
   * Reads `withFrame` off the menu rather than the module mirror: the
   * menu re-renders its popover (calling back in here) before it fires
   * `onChange`, so the mirror is one interaction stale mid-toggle.
   */
  function captureSourceSize() {
    const wantFrame = sizeMenu ? sizeMenu.settings.withFrame : captureWithFrame;
    const fimg = wantFrame && sim && sim._bezel ? sim._bezel.frameImg : null;
    if (fimg && fimg.naturalWidth > 0) {
      return { width: fimg.naturalWidth, height: fimg.naturalHeight };
    }
    if (lastPaintedSize.w && lastPaintedSize.h) {
      const divisor = readActiveQuality().scale || 1;
      return {
        width: lastPaintedSize.w * divisor,
        height: lastPaintedSize.h * divisor,
      };
    }
    return null;
  }

  function mountCaptureSizeMenu() {
    const host = document.getElementById('simCaptureSizeHost');
    if (!host || !window.CaptureSizeMenu) return;
    if (sizeMenu) { sizeMenu.detach(); sizeMenu = null; }
    host.innerHTML = '';
    sizeMenu = new window.CaptureSizeMenu({
      storageKey: CAPTURE_STORAGE_KEY,
      showFrameToggle: true,
      sourceSize: captureSourceSize,
      onChange: (settings) => {
        // `withFrame` lives on the settings value; this mirror is what
        // the rest of the file (and the legacy `_simToggleFrame` entry
        // point) reads, so there is still exactly one flag.
        captureWithFrame = settings.withFrame;
        renderCaptureSizeHint();
      },
    });
    sizeMenu.mount(host);
    // CaptureSettings defaults `withFrame` to true, but the checkbox this
    // menu replaces shipped unchecked — and it drives the *recorder* as
    // well as the screenshot. Seed the first run to false so an upgrading
    // user's recordings don't silently gain a bezel; once they've touched
    // the switch, the persisted value wins.
    if (!hasStoredCaptureSettings()) sizeMenu.apply({ withFrame: false });
    captureWithFrame = sizeMenu.settings.withFrame;
    renderCaptureSizeHint();
  }

  function hasStoredCaptureSettings() {
    try {
      return window.localStorage.getItem(CAPTURE_STORAGE_KEY) != null;
    } catch {
      return false;  // Safari private browsing — treat as first run
    }
  }

  // The pixels the current selection resolves to, shown under the two
  // capture buttons. Reads the same `plan()` the capture surfaces do, so
  // it can't drift from what they produce once both are on the shared
  // vocabulary (capture-gallery.js / recorder.js land alongside this).
  function renderCaptureSizeHint() {
    const el = document.getElementById('simCaptureSizeOut');
    if (!el) return;
    const settings = captureSettings();
    const source = captureSourceSize();
    if (!settings || !source) { el.textContent = ''; return; }
    const plan = settings.plan(source.width, source.height);
    if (!plan.width || !plan.height) { el.textContent = ''; return; }
    el.textContent = settings.size.isNative
      ? `${plan.width} × ${plan.height} · native`
      : `${plan.width} × ${plan.height} · ${settings.size.label} · ${settings.fit}`;
  }

  function renderGallery() {
    if (!gallery) return;
    gallery.renderInto(
      document.getElementById('simCaptureGallery'),
      document.getElementById('simCaptureCount'),
    );
  }

  // --- Sidebar callbacks (invoked from sim-stream.html onclick=…) ---

  window._simStopStream = stopStream;
  window._simButton = (b) => {
    if (!sim) return;
    log(`button(${b})`);
    sim.pressButton(b);
  };
  window._simKey = (k) => {
    if (!sim || !sim.keyboard) return;
    // Legacy sidebar fires raw HID numbers — the modern wire dialect
    // accepts W3C codes (`"Enter"`, `"Backspace"`, …) which the
    // backend resolves to HID. Numbers stay forwarded for back-compat
    // with the existing sidebar HTML; new sidebar code should call
    // `sim.keyboard.key('Enter')` directly.
    log(`key(${k})`);
    sim.keyboard.key(k);
  };
  window._simSendText = () => {
    const el = document.getElementById('simTextInput');
    const t = el ? el.value : '';
    if (!t || !sim) return;
    log(`type("${t.slice(0, 20)}")`);
    sim.type(t);
    el.value = '';
  };
  // The standalone "with frame" checkbox is gone — CaptureSizeMenu's
  // "Include bezel" switch is the same flag. This entry point stays for
  // anything still calling it (host SPA, plugins) and routes into the
  // menu so both stay one state.
  window._simToggleFrame = (checked) => {
    if (sizeMenu) sizeMenu.apply({ withFrame: !!checked });
    else captureWithFrame = !!checked;
  };

  window._simSetFormat = (btn) => {
    if (!btn) return;
    // Storing an undecodable format wedges the origin (#71).
    const wanted = window.StreamFormat && window.StreamFormat.named(btn.dataset.v);
    if (!wanted || !wanted.isPlayable(decodeCapabilities())) return;
    const fmt = wanted.id;
    if (localStorage.getItem(FORMAT_KEY) === fmt && btn.classList.contains('btn-primary')) return;
    localStorage.setItem(FORMAT_KEY, fmt);
    document.querySelectorAll('#simFormatRow .simFmt').forEach((b) => b.classList.remove('btn-primary'));
    btn.classList.add('btn-primary');
    log(`Format → ${fmt.toUpperCase()}`);
    if (activeUdid) {
      const u = activeUdid, n = activeName;
      stopStream();
      setTimeout(() => startStream(u, n), 100);
    }
  };

  window._simSetQuality = (btn) => {
    if (!session || !btn) return;
    const k = btn.dataset.k, v = parseInt(btn.dataset.v, 10);
    document.querySelectorAll(`#simStreamSidebar .simQ[data-k="${k}"]`)
      .forEach((b) => b.classList.remove('btn-primary'));
    btn.classList.add('btn-primary');
    // ReconfigParser keys: set_scale / set_fps / set_bitrate.
    const wire = { scale: 'set_scale', fps: 'set_fps', bps: 'set_bitrate' }[k];
    const field = { scale: 'scale', fps: 'fps', bps: 'bps' }[k];
    if (!wire) return;
    session.send({ type: wire, [field]: v });
    log(`${k}=${v}`);
  };

  window._simCapture = async () => {
    if (!gallery) return;
    try {
      // Belt and braces: `settings` is the new shape CaptureGallery reads
      // for output size / fit / background, `withFrame` + `naturalSize`
      // are the shape it has always read. Passing both means this call
      // site works against either version of capture-gallery.js — the
      // two land on separate branches and neither has to wait for the
      // other. Drop the legacy pair once `settings` is required.
      const r = await gallery.capture({
        settings: captureSettings(),
        withFrame: captureWithFrame,
        naturalSize: lastPaintedSize,
      });
      log(`Captured${r.withFrame ? ' with frame' : ''} (${r.w}x${r.h})`);
      renderGallery();
    } catch {
      log('Capture failed', true);
    }
  };

  // --- Recording ----------------------------------------------------
  // Browser-side recording: captureStream() the live decoded canvas
  // and feed it to MediaRecorder. No server round-trip, no offscreen
  // canvases — whatever's in the live canvas is what gets recorded.
  window._simToggleRecord = async () => {
    if (!sim) return;

    if (recordingState.active) {
      const rec = recordingState.recorder;
      // Optimistic UI: clear the live timer the instant the user
      // clicks Stop. MediaRecorder.stop fires onstop after the final
      // chunk lands; that can take a beat for longer recordings.
      recordingState.active = false;
      recordingState.recorder = null;
      if (recordingState.timer) { clearInterval(recordingState.timer); recordingState.timer = null; }
      const label = document.getElementById('simRecordLabel');
      const timer = document.getElementById('simRecordTimer');
      const btn   = document.getElementById('simRecordBtn');
      if (label) label.textContent = 'Saving…';
      if (timer) timer.textContent = '';
      if (btn)   btn.classList.remove('recording');
      restoreSavedQuality();
      try {
        const artifact = await rec.stop();
        onRecordFinished(artifact);
      } catch (err) {
        onRecordError(err);
      }
      return;
    }

    if (!window.BrowserRecorder || !window.BrowserRecorder.isAvailable()) {
      log('Recording: MediaRecorder not available in this browser', true);
      return;
    }
    try {
      // Bump the live stream to full quality so the source canvas the
      // recorder reads is at native resolution. The composite canvas
      // is bezel-sized; drawImage upscaling a low-res canvas is the
      // single biggest visible-quality drag, so we ratchet here and
      // restore on stop.
      recordingState.savedQuality = readActiveQuality();
      applyQuality({ scale: 1, fps: 60, bps: 8_000_000 });

      // The bezel switch drives both screenshots AND recordings —
      // passing `screen: null` to the recorder makes it fall through to
      // bare-screen mode (no bezel composite).
      //
      // Belt and braces, same as `_simCapture`: `settings` carries the
      // output size for a recorder that understands it, while the
      // canvas / frameImg / screen / overlayHost / fps quartet is what
      // today's recorder.js reads. Both shapes ship together so this
      // call site is correct whichever version is loaded.
      const rec = new window.BrowserRecorder({
        settings:    captureSettings(),
        canvas:      sim.canvas,
        frameImg:    captureWithFrame ? sim._bezel.frameImg     : null,
        screen:      captureWithFrame ? sim.screen.def          : null,
        overlayHost: sim.pinchOverlayContainer,
        fps: 60,
      });
      rec.start();
      recordingState.recorder = rec;
      onRecordStarted();
    } catch (err) {
      onRecordError(err);
    }
  };

  // Put the pre-recording knobs back. Unconditional on every path that
  // leaves "not recording": stop, *and* a start that threw. Restoring
  // only on stop pins the live stream at scale 1 / 60fps / 8 Mbps for
  // the rest of the session when `new BrowserRecorder(...)` or
  // `.start()` fails, with no recording to show for it and no way back
  // short of a reload.
  function restoreSavedQuality() {
    if (!recordingState.savedQuality) return;
    applyQuality(recordingState.savedQuality);
    recordingState.savedQuality = null;
  }

  function onRecordStarted() {
    recordingState.active = true;
    recordingState.startedAt = Date.now();
    if (recordingState.timer) clearInterval(recordingState.timer);
    recordingState.timer = setInterval(updateRecordTimer, 250);
    updateRecordButton();
    updateRecordTimer();
    log('Recording started');
  }

  function onRecordFinished(artifact) {
    updateRecordButton();
    updateRecordTimer();
    if (!artifact || typeof artifact.url !== 'string') return;
    recordingState.entries.unshift(artifact);
    renderRecordList();
    log(`Recorded ${formatBytes(artifact.bytes)} (${formatDuration(artifact.durationSeconds)})`);
  }

  function onRecordError(err) {
    recordingState.active = false;
    recordingState.recorder = null;
    restoreSavedQuality();  // a start that never began must not keep the bump
    if (recordingState.timer) { clearInterval(recordingState.timer); recordingState.timer = null; }
    updateRecordButton();
    updateRecordTimer();
    log('Record: ' + (err && err.message ? err.message : 'failed'), true);
  }

  function resetRecordingUI() {
    recordingState.active = false;
    recordingState.recorder = null;
    recordingState.savedQuality = null;
    recordingState.startedAt = 0;
    if (recordingState.timer) { clearInterval(recordingState.timer); recordingState.timer = null; }
    // Free Blob URLs we own — keeps long sessions from leaking memory.
    recordingState.entries.forEach((e) => {
      if (e.url && e.url.startsWith('blob:')) URL.revokeObjectURL(e.url);
    });
    recordingState.entries = [];
  }

  function updateRecordButton() {
    const btn = document.getElementById('simRecordBtn');
    const label = document.getElementById('simRecordLabel');
    if (!btn || !label) return;
    btn.classList.toggle('recording', recordingState.active);
    label.textContent = recordingState.active ? 'Stop' : 'Record';
  }

  function updateRecordTimer() {
    const el = document.getElementById('simRecordTimer');
    if (!el) return;
    if (!recordingState.active) { el.textContent = ''; return; }
    const elapsed = (Date.now() - recordingState.startedAt) / 1000;
    el.textContent = formatDuration(elapsed);
  }

  function renderRecordList() {
    const host = document.getElementById('simRecordList');
    if (!host) return;
    if (!recordingState.entries.length) { host.innerHTML = ''; return; }
    const head = `<div class="rec-head">Recordings (${recordingState.entries.length})</div>`;
    const rows = recordingState.entries.map((e) => `
      <a href="${e.url}" download="${escapeHTML(e.filename)}" title="Download recording">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="12" height="12"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
        <span>${formatDuration(e.duration)}</span>
        <span class="rec-meta">${formatBytes(e.bytes)}</span>
      </a>`).join('');
    host.innerHTML = head + rows;
  }

  function formatDuration(seconds) {
    if (!isFinite(seconds) || seconds < 0) seconds = 0;
    const m = Math.floor(seconds / 60);
    const s = Math.floor(seconds % 60);
    return `${m}:${String(s).padStart(2, '0')}`;
  }

  function formatBytes(bytes) {
    if (!bytes || bytes < 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    let n = bytes, i = 0;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
    return `${n.toFixed(n < 10 && i ? 1 : 0)} ${units[i]}`;
  }

  // --- Affordance handler ---
  // Stream click on the list page navigates to `/simulators/<udid>`
  // — the focus-mode page owned by sim-native.js — instead of
  // swapping the inline #simPluginView in place. The deep-link route
  // is the canonical "stream this device" surface (browser back
  // returns to the list, share-link works, no inline-view flash).
  window.simAffordanceHandlers = window.simAffordanceHandlers || {};
  window.simAffordanceHandlers['stream'] = (id) => {
    location.href = '/simulators/' + encodeURIComponent(id);
  };

  // --- Hash trigger ---
  // Focus mode (sim-native.js) exposes a "sidebar view" floating
  // button that navigates here with `#stream=<udid>`. When that
  // hash is present on load, auto-open the inline stream view for
  // the named device so the user lands directly in the sidebar
  // layout instead of having to click Stream again.
  async function openFromHash() {
    const match = location.hash.match(/^#stream=([^&]+)/);
    if (!match) return;
    const udid = decodeURIComponent(match[1]);
    if (!udid) return;
    history.replaceState(null, '', location.pathname + location.search);
    let name = 'Simulator';
    try {
      const r = await fetch('/simulators.json', { cache: 'no-store' });
      if (r.ok) {
        const json = await r.json();
        const all = (json.running || []).concat(json.available || []);
        const hit = all.find((d) => (d.id || d.udid) === udid);
        if (hit && hit.name) name = hit.name;
      }
    } catch (_) { /* fall through with default name */ }
    startStream(udid, name);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', openFromHash, { once: true });
  } else {
    openFromHash();
  }

  console.log('[ASC Pro] sim-stream.js loaded (modular)');
})();
