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

  let activeUdid = null;
  let activeName = null;
  let captureWithFrame = false;
  let lastPaintedSize = { w: 0, h: 0 };

  // Recording state. The server runs ffmpeg with `-c copy` on the AVCC
  // stream's H.264 NALs — no re-encode, near-zero CPU. UI flips between
  // idle / recording on the start_record / stop_record verbs the
  // server acknowledges back over the same WS as text frames.
  //   state.active : true between record_started and record_finished
  //   state.startedAt : ms timestamp for the live timer
  //   state.timer : interval handle that ticks the toolbar label
  //   state.entries : finished recordings (download links)
  const recordingState = { active: false, startedAt: 0, timer: null, entries: [] };

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

    session = new window.StreamSession({
      udid, format, version: 'v2',
      canvas: surface.canvas,
      onSize: (w, h) => { lastPaintedSize = { w, h }; },
      onFps:  (fps) => {
        const el = document.getElementById('simStreamFps');
        if (el) el.textContent = fps + ' fps';
      },
      onLog: log,
      onText: handleServerText,
    });
    session.start();

    wireInput(udid, frame.screenSize());
    wireKeyboard();

    gallery = new window.CaptureGallery({
      udid, layout, frameImg: surface.frameImg,
    });
    gallery.clear();
    renderGallery();
  }

  function stopStream() {
    if (session) { session.stop(); session = null; }
    if (mouseSource) { mouseSource.detach(); mouseSource = null; }
    if (pinchOverlay) { pinchOverlay.clear(); pinchOverlay = null; }
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
      // session opened. SimInput speaks the asc-cli plugin's dialect
      // (`kind:"tap"`, `kind:"touchDown"` with `fingers[]`); Baguette's
      // GestureRegistry expects its own dialect (`type:"tap"`,
      // `type:"touch1-down"`, `startX/endX` instead of `x1/x2`). The
      // translator lives here — the only place that knows it's
      // bridging two wire dialects.
      transport: (payload) => {
        const wire = toBaguetteWire(payload);
        if (wire) session.send(wire);
      },
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
  // Toggle handler bound to the Record button. The server side runs
  // ffmpeg with `-c copy`, so this only works when the active stream
  // format is `avcc` — pickFormat() persists the user's choice in
  // localStorage; on `mjpeg` we point the user at the format toggle
  // rather than firing a verb the server would reject.
  window._simToggleRecord = () => {
    if (!session) return;
    if (recordingState.active) {
      // Optimistic UI: stop the live timer right away, swap label to
      // "Saving…" — the server's record_finished may take a moment
      // because ffmpeg's moov-atom finalisation runs on a detached
      // task. onRecordFinished/onRecordError flips us back to idle.
      recordingState.active = false;
      if (recordingState.timer) { clearInterval(recordingState.timer); recordingState.timer = null; }
      const label = document.getElementById('simRecordLabel');
      const timer = document.getElementById('simRecordTimer');
      const btn = document.getElementById('simRecordBtn');
      if (label) label.textContent = 'Saving…';
      if (timer) timer.textContent = '';
      if (btn) btn.classList.remove('recording');
      session.send({ type: 'stop_record' });
      return;
    }
    if (localStorage.getItem('asc.simFormat') === 'mjpeg') {
      log('Recording requires H.264 — switch the format above.', true);
      return;
    }
    session.send({ type: 'start_record' });
  };

  function handleServerText(obj) {
    if (!obj || typeof obj.type !== 'string') return;
    switch (obj.type) {
      case 'record_started':  onRecordStarted();   break;
      case 'record_finished': onRecordFinished(obj); break;
      case 'record_error':    onRecordError(obj);  break;
      default: break;
    }
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

  function onRecordFinished(obj) {
    recordingState.active = false;
    if (recordingState.timer) { clearInterval(recordingState.timer); recordingState.timer = null; }
    updateRecordButton();
    updateRecordTimer();
    if (obj && typeof obj.url === 'string') {
      recordingState.entries.unshift({
        url: obj.url,
        filename: obj.filename || 'recording.mp4',
        duration: typeof obj.duration === 'number' ? obj.duration : 0,
        bytes:    typeof obj.bytes === 'number'    ? obj.bytes    : 0,
      });
      renderRecordList();
      log(`Recorded ${formatBytes(obj.bytes)} (${formatDuration(obj.duration)})`);
    }
  }

  function onRecordError(obj) {
    recordingState.active = false;
    if (recordingState.timer) { clearInterval(recordingState.timer); recordingState.timer = null; }
    updateRecordButton();
    updateRecordTimer();
    log('Record: ' + ((obj && obj.error) || 'failed'), true);
  }

  function resetRecordingUI() {
    recordingState.active = false;
    recordingState.startedAt = 0;
    if (recordingState.timer) { clearInterval(recordingState.timer); recordingState.timer = null; }
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
      <a href="${e.url}" download="${escapeHTML(e.filename)}" title="Download MP4">
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

  // SimInput → Baguette wire-format translator. SimInput's payload
  // uses the asc-cli plugin's dialect; Baguette's GestureRegistry
  // expects its own. Returns the rewritten dict, or null when the
  // gesture has no Baguette equivalent (e.g. `key`/`type` aren't on
  // Baguette's host-HID path yet — they fall through to AXe in the
  // plugin world; standalone serve drops them with a log).
  // SimInput sends normalized [0,1] coords + `width`/`height` device
  // points. Baguette's wire (per `IndigoHIDInput.sendMouse`) expects
  // x/y in *device-point space* and re-normalizes internally — the
  // plugin's TapHandler does this multiplication too. Skipping it
  // sends every touch to the literal top-left corner.
  function toBaguetteWire(p) {
    const w = p.width, h = p.height;
    const base = { width: w, height: h };
    const px = (x) => x * w;
    const py = (y) => y * h;
    switch (p.kind) {
      case 'tap':
        return { type: 'tap', x: px(p.x), y: py(p.y),
                 duration: p.duration ?? 0.05, ...base };
      case 'swipe':
        return {
          type: 'swipe',
          startX: px(p.x1), startY: py(p.y1),
          endX:   px(p.x2), endY:   py(p.y2),
          duration: p.duration ?? 0.25,
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
        log(`${p.kind}: not on Baguette's host-HID path`, true);
        return null;
      default:
        return null;
    }
  }

  /// `touchDown`/`touchMove`/`touchUp` with N fingers fan out to
  /// `touch1-<phase>` (one finger) or `touch2-<phase>` (two fingers).
  /// Anything else gets dropped — Baguette only supports 1 or 2.
  function phasedTouchWire(p, base, px, py) {
    const phase = p.kind.replace('touch', '').toLowerCase(); // down|move|up
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

  // --- Affordance handler ---
  window.simAffordanceHandlers = window.simAffordanceHandlers || {};
  window.simAffordanceHandlers['stream'] = (id, name) => startStream(id, name);

  console.log('[ASC Pro] sim-stream.js loaded (modular)');
})();
