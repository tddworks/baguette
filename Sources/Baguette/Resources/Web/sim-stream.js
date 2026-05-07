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
  let frame = null;         // DeviceFrame
  let surface = null;       // { screenArea, canvas, frameImg }
  let gallery = null;       // CaptureGallery
  let simInput = null;
  let mouseSource = null;
  let pinchOverlay = null;
  let logPanel = null;
  let axInspector = null;   // AXInspector — accessibility-tree overlay

  let activeUdid = null;
  let activeName = null;
  let captureWithFrame = false;
  let lastPaintedSize = { w: 0, h: 0 };

  // Recording state. BrowserRecorder spins up a compose canvas only
  // while active; references are pulled from what's already on the
  // page (frameImg from DeviceFrame, layout from chrome.json, pinch
  // dots from PinchOverlay's DOM container). Idle cost: zero.
  //   state.recorder      : BrowserRecorder instance during a recording
  //   state.layout        : cached chrome layout (composite + screen rect)
  //   state.savedQuality  : pre-recording stream config; restored on stop
  //   state.active        : true between start() and stop()
  //   state.startedAt     : ms timestamp for the live timer
  //   state.timer         : interval handle that ticks the toolbar label
  //   state.entries       : finished recordings (download links)
  const recordingState = {
    recorder: null, layout: null, savedQuality: null,
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

  function pickFormat() {
    const stored = localStorage.getItem('asc.simFormat');
    if (stored === 'avcc' || stored === 'mjpeg') return stored;
    return window.FrameDecoder.isHardwareAvailable() ? 'avcc' : 'mjpeg';
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

    // Don't `force-cache` — chrome.json's shape evolves (e.g. button
    // margins were added; innerCornerRadius math has been corrected),
    // and `force-cache` would pin the browser to whatever it pulled
    // first, ignoring the server's current response. The default
    // policy plus the server's no-cache header keeps clients in sync.
    const layout = await fetch(
      `/simulators/${encodeURIComponent(udid)}/chrome.json`
    ).then((r) => (r.ok ? r.json() : null)).catch(() => null);

    frame = new window.DeviceFrame({ udid, layout });
    surface = frame.mount(document.getElementById('simDeviceFrame'));

    const format = pickFormat();
    requestAnimationFrame(() => {
      document.querySelectorAll('#simFormatRow .simFmt').forEach((b) => {
        b.classList.toggle('btn-primary', b.dataset.v === format);
      });
    });
    log(`Stream: ${format.toUpperCase()}${format === 'avcc' ? ' (hw-decoded)' : ''}`);

    // Text-frame router. The stream WS carries binary video frames
    // and JSON envelopes (describe_ui_result, server pushes). The
    // accessibility inspector consumes describe_ui_result; anything
    // it doesn't claim falls through to the decoder's error logger.
    const onStreamText = (env) => {
      if (axInspector && axInspector.handleEnvelope(env)) return true;
      return false;
    };

    session = new window.StreamSession({
      udid, format, version: 'v2',
      canvas: surface.canvas,
      onSize: (w, h) => { lastPaintedSize = { w, h }; },
      onFps:  (fps) => {
        const el = document.getElementById('simStreamFps');
        if (el) el.textContent = fps + ' fps';
      },
      onLog: log,
      onText: onStreamText,
    });
    session.start();

    wireInput(udid, frame.screenSize());
    wireKeyboard();

    // Cache the chrome layout for the recorder. The bezel <img> and
    // pinch overlay are already in the page; the recorder pulls them
    // by reference at start-time, so nothing extra runs while idle.
    recordingState.layout = layout;

    gallery = new window.CaptureGallery({
      udid, layout, frameImg: surface.frameImg,
    });
    gallery.clear();
    renderGallery();

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
        screenArea: surface.screenArea,
        send: (payload) => session && session.send(payload),
        getDeviceSize: () => frame.screenSize(),
      });
    }
  }

  function stopStream() {
    if (recordingState.recorder) {
      try { recordingState.recorder.cancel(); } catch { /* ignore */ }
    }
    if (axInspector) { axInspector.detach(); axInspector = null; }
    if (session) { session.stop(); session = null; }
    if (mouseSource) { mouseSource.detach(); mouseSource = null; }
    if (pinchOverlay) { pinchOverlay.clear(); pinchOverlay = null; }
    if (logPanel) { logPanel.detach(); logPanel = null; }
    simInput = null;
    frame = null;
    surface = null;
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

  function wireInput(udid, screenSize) {
    simInput = new SimInput({
      udid,
      log,
      // Input + control rides over the same WebSocket the stream
      // session opened. SimInputBridge translates SimInput's asc-cli
      // dialect (kind:"tap", fingers[]) to Baguette's GestureRegistry
      // dialect (type:"tap", touch1-/touch2-, points-not-normalized);
      // also shared by farm-tile.js and sim-native.js.
      transport: window.SimInputBridge.makeTransport(session, log),
    });
    simInput.setScreenSize(screenSize.w, screenSize.h);
    pinchOverlay = new PinchOverlay(surface.screenArea);
    mouseSource = new MouseGestureSource({
      el: surface.screenArea,
      input: simInput,
      overlay: pinchOverlay,
      log,
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
        log(`key(${e.key})`);
        simInput.key(hid);
        return;
      }
      if (e.key.length === 1 && !e.altKey) {
        e.preventDefault();
        simInput.type(e.key);
      }
    });
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
  window._simButton = (b) => { if (!simInput) return; log(`button(${b})`); simInput.button(b); };
  window._simKey    = (k) => { if (!simInput) return; log(`key(${k})`); simInput.key(k); };
  window._simSendText = () => {
    const el = document.getElementById('simTextInput');
    const t = el ? el.value : '';
    if (!t || !simInput) return;
    log(`type("${t.slice(0, 20)}")`);
    simInput.type(t);
    el.value = '';
  };
  window._simToggleFrame = (checked) => { captureWithFrame = checked; };

  window._simSetFormat = (btn) => {
    if (!btn) return;
    const fmt = btn.dataset.v;
    if (fmt !== 'avcc' && fmt !== 'mjpeg') return;
    if (localStorage.getItem('asc.simFormat') === fmt && btn.classList.contains('btn-primary')) return;
    localStorage.setItem('asc.simFormat', fmt);
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
      const r = await gallery.capture({
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
    if (!surface) return;

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
      // Restore the stream quality the user had before we bumped it.
      if (recordingState.savedQuality) {
        applyQuality(recordingState.savedQuality);
        recordingState.savedQuality = null;
      }
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

      const rec = new window.BrowserRecorder({
        canvas:      surface.canvas,
        frameImg:    surface.frameImg,
        layout:      recordingState.layout,
        overlayHost: pinchOverlay ? pinchOverlay.container : null,
        fps: 60,
      });
      rec.start();
      recordingState.recorder = rec;
      onRecordStarted();
    } catch (err) {
      onRecordError(err);
    }
  };

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
    if (recordingState.timer) { clearInterval(recordingState.timer); recordingState.timer = null; }
    updateRecordButton();
    updateRecordTimer();
    log('Record: ' + (err && err.message ? err.message : 'failed'), true);
  }

  function resetRecordingUI() {
    recordingState.active = false;
    recordingState.recorder = null;
    recordingState.layout = null;
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
  window.simAffordanceHandlers = window.simAffordanceHandlers || {};
  window.simAffordanceHandlers['stream'] = (id, name) => startStream(id, name);

  console.log('[ASC Pro] sim-stream.js loaded (modular)');
})();
