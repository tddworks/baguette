// FarmFocus — right-pane controller for the focused device.
//
// Borrows the FarmTile's existing canvas (no second WS, no second
// decoder) and re-parents it into the focus preview. While focused,
// the tile runs in `full` mode (60fps / scale 1 / 6 Mbps); on
// dispose, it's demoted back to thumbnail and the canvas returns to
// its grid/wall/list host.
//
// Telemetry numbers come from the same FarmTile.onTelemetry feed
// FarmApp wires into all tiles — no separate gauge timer.
// The farm's own slot in the shared capture-size vocabulary — each
// surface persists its selection separately (`asc.capture.native`,
// `asc.capture.farm`, …) because "square for marketing shots on the
// native page" rarely means "square for every farm recording too".

import { CaptureSizeMenu } from '../capture/capture-size-menu.js';
import { BrowserRecorder } from '../capture/recorder.js';
import { FarmViews } from './farm-views.js';
const CAPTURE_STORAGE_KEY = 'asc.capture.farm';

function FarmFocus(host) {
  this.host = host;
  this.tile = null;
  this.device = null;
  this.previewScreen = null;   // <div class="screen"> the canvas lives in while focused
  this.fpsEl = null;
  this.latEl = null;
  this.brEl  = null;

  // Recording state for the focused device. Reset every time `show`
  // (re)builds the focus pane — different device → different stream
  // → no carry-over. BrowserRecorder captureStream's the focused
  // tile's live canvas; nothing else to stitch.
  this.recording = {
    recorder: null,
    active: false, startedAt: 0, timer: null,
    entries: [],
    // Frozen at Record-press time: what the user asked for, the size we
    // predicted, and the size the recorder's compose canvas actually is.
    settings: null, plannedSize: null, outputSize: null,
  };

  // Output-size picker (capture/capture-size-menu.js). Rebuilt on every
  // `show` because `show` replaces the pane's innerHTML wholesale; the
  // selection itself survives in localStorage under CAPTURE_STORAGE_KEY.
  this.captureMenu = null;
  // Defaulted here so `_captureSourceSize` is safe to call before the
  // first `show` wires the real closure in.
  this._getRecorderContext = () => null;
}

FarmFocus.prototype.show = function (device, tile, callbacks) {
  this.device = device;
  this.tile = tile;
  this.host.innerHTML = `
    <div class="focus-head">
      <div class="row1">
        <div class="tag">Focused&nbsp;Device</div>
        <button class="close" data-action="close" title="Clear">✕</button>
      </div>
      <h2>${esc(device.name)}</h2>
      <div class="meta">
        <span>${esc(device.runtime)}</span>
        <span>${device.udid}</span>
        <span>${esc(device.platform)}</span>
      </div>
    </div>

    <div class="preview">
      <div class="screen ${shape(device.platform)}" data-role="focus-screen"></div>
    </div>

    <div class="controls">
      <h4>Live Telemetry</h4>
      <div class="control-row" style="border:0">
        <span class="label">FPS</span>
        <span class="num" data-readout="fps">—</span>
      </div>
      <div class="control-row" style="border:0">
        <span class="label">Latency</span>
        <span class="num" style="color:var(--amber)" data-readout="lat">—</span>
      </div>
      <div class="control-row" style="border:0">
        <span class="label">Bitrate</span>
        <span class="num" style="color:var(--cyan)" data-readout="br">—</span>
      </div>
    </div>

    <div class="controls">
      <h4>Hardware Buttons</h4>
      <div class="preset-row">
        <button class="preset" data-button="home">Home</button>
        <button class="preset" data-button="lock">Lock</button>
        <button class="preset" data-button="vol-up">Vol +</button>
      </div>
      <div class="preset-row" style="margin-top:6px">
        <button class="preset" data-button="vol-down">Vol −</button>
        <button class="preset" data-button="screenshot">Snap UI</button>
        <button class="preset" data-button="rotate">Rotate</button>
      </div>
    </div>

    <div class="controls">
      <h4>Capture Output</h4>
      <div class="capture-row">
        <span class="label">Output</span>
        <span class="dims" data-readout="capture-dims" title="Resolved recording output">—</span>
      </div>
      <div class="capture-picker" data-role="capture-size"></div>
    </div>

    <div class="controls">
      <h4>Stream Controls</h4>
      <div class="preset-row">
        <button class="preset" data-action="force-idr">Force IDR</button>
        <button class="preset" data-action="snapshot">Snapshot</button>
        <button class="preset" data-action="open-tab">Open Tab</button>
      </div>
      <div class="preset-row" style="margin-top:10px">
        <button class="preset" data-action="boot">Boot</button>
        <button class="preset" data-action="shutdown">Shutdown</button>
        <button class="preset" data-action="restart">Restart</button>
      </div>
      <button class="preset record-btn" data-action="toggle-record" style="margin-top:10px;width:100%" title="Record the focused view with bezel + touch overlay (saved locally)">
        <span class="record-dot" style="display:inline-block;width:8px;height:8px;border-radius:50%;background:currentColor;margin-right:6px"></span>
        <span data-readout="record-label">Record</span>
        <span data-readout="record-timer" style="margin-left:auto;font-variant-numeric:tabular-nums"></span>
      </button>
      <div data-readout="record-list" class="record-list" style="margin-top:8px;display:flex;flex-direction:column;gap:4px"></div>
    </div>`;

  // FarmApp re-parents the live canvas into `previewScreen` after
  // we return — that way the bezel toggle + chrome layout stay in
  // one place (tile.attach()) instead of being split across two
  // mounting paths. Here we only build the chrome.
  this.previewScreen = this.host.querySelector('[data-role="focus-screen"]');
  this.fpsEl = this.host.querySelector('[data-readout="fps"]');
  this.latEl = this.host.querySelector('[data-readout="lat"]');
  this.brEl  = this.host.querySelector('[data-readout="br"]');
  this._resetRecording();

  // Wire actions back to the orchestrator.
  this.host.querySelector('[data-action="close"]').onclick     = () => callbacks.onClose();
  this.host.querySelector('[data-action="force-idr"]').onclick = () => tile?.forceIdr();
  this.host.querySelector('[data-action="snapshot"]').onclick  = () => tile?.snapshot();
  this.host.querySelector('[data-action="open-tab"]').onclick  = () => callbacks.onOpenTab(device);
  this.host.querySelector('[data-action="boot"]').onclick      = () => callbacks.onLifecycle(device, 'boot');
  this.host.querySelector('[data-action="shutdown"]').onclick  = () => callbacks.onLifecycle(device, 'shutdown');
  this.host.querySelector('[data-action="restart"]').onclick   = () => callbacks.onLifecycle(device, 'restart');

  // Hardware buttons — UI exposes the full set (home, lock, volume,
  // screenshot, rotate). Today only `home` and `lock` reach
  // Baguette's host-HID path (Press.swift); the rest land server-side
  // as ignored gestures until DeviceButton is widened. The buttons
  // are wired so the UI stays useful as soon as the Domain layer
  // grows the cases — no client change needed.
  const buttonMap = {
    'home':       'home',
    'lock':       'lock',
    'vol-up':     'volume-up',
    'vol-down':   'volume-down',
    'screenshot': 'screenshot',
    'rotate':     'rotate'
  };
  this.host.querySelectorAll('[data-button]').forEach(btn => {
    btn.onclick = () => {
      const name = buttonMap[btn.dataset.button];
      if (name) callbacks.onButton?.(name);
    };
  });

  // Recording toggle. The recorder lives client-side and composes
  // bezel + screen + pinch overlay from existing page elements.
  // `getRecorderContext` is a closure FarmApp passes in so a
  // re-focus mid-recording can't strand the recorder on a stale tile.
  this._getRecorderContext = callbacks.getRecorderContext || (() => null);
  const recBtn = this.host.querySelector('[data-action="toggle-record"]');
  if (recBtn) {
    recBtn.onclick = () => this._toggleRecord(recBtn);
  }

  // Mounted last: the menu's `sourceSize` closure reads the recorder
  // context, which only exists once the callbacks above are wired.
  this._mountCaptureMenu();
};

// ---- capture output size -------------------------------------------

// Guarded end to end: this is the last thing `show` does, and FarmApp
// re-parents the live canvas + promotes the tile *after* `show`
// returns. A capture module that failed to load must cost the user a
// size picker, never the video.
FarmFocus.prototype._mountCaptureMenu = function () {
  if (this.captureMenu) { this.captureMenu.detach(); this.captureMenu = null; }
  const host = this.host.querySelector('[data-role="capture-size"]');
  if (!host) return;
  try {
    this.captureMenu = new CaptureSizeMenu({
      storageKey: CAPTURE_STORAGE_KEY,
      showFrameToggle: true,
      sourceSize: () => this._captureSourceSize(),
      onChange: () => this._renderCaptureDims(),
    }).mount(host);
  } catch (err) {
    this.captureMenu = null;
    console.warn('[FarmFocus] capture size picker unavailable:', err && err.message);
  }
  this._renderCaptureDims();
};

/** The CaptureSettings a recording started right now would use. */
FarmFocus.prototype.captureSettings = function () {
  return this.captureMenu ? this.captureMenu.settings : null;
};

// What the recorder's compose canvas comes out at before the capture
// size is applied. Mirrors recorder.js `composeSize`: with a bezel to
// composite, the recording is the definition's viewport; otherwise it
// is the live canvas's own pixels. Keeping the two in step is what
// makes the readout the number the file actually gets.
FarmFocus.prototype._captureSourceSize = function () {
  const ctx = this._getRecorderContext();
  if (!ctx) return null;
  const settings = this.captureSettings();
  const wantsFrame = !settings || settings.withFrame;
  if (wantsFrame && ctx.frameImg && ctx.frameImg.naturalWidth > 0 &&
      ctx.screen && ctx.screen.viewport) {
    return { width: ctx.screen.viewport.width, height: ctx.screen.viewport.height };
  }
  if (ctx.canvas && ctx.canvas.width > 0) {
    return { width: ctx.canvas.width, height: ctx.canvas.height };
  }
  return null;
};

// While idle this is a prediction; once recording it's the compose
// canvas the recorder actually built, which is the only number that
// can't be wrong. They differ only against a BrowserRecorder that
// doesn't understand `settings` yet — hence the `stale` flag rather
// than silently showing a size the file won't have.
FarmFocus.prototype._renderCaptureDims = function () {
  const el = this.host.querySelector('[data-readout="capture-dims"]');
  if (!el) return;
  const recording = this.recording.active && this.recording.outputSize;
  const out = recording ? this.recording.outputSize : this._resolvedOutputSize();
  const planned = recording ? this.recording.plannedSize : out;
  const honoured = sameSize(planned, out);
  const text = out ? out.width + '\u00d7' + out.height : '\u2014';
  if (el.textContent !== text) el.textContent = text;
  el.classList.toggle('stale', !!out && !honoured);
  el.title = honoured
    ? 'Resolved recording output'
    : 'This recorder records at its own size — the chosen capture size was not applied';
};

FarmFocus.prototype._resolvedOutputSize = function () {
  const settings = this.captureSettings();
  const source = this._captureSourceSize();
  if (!settings || !source) return null;
  const plan = settings.plan(source.width, source.height);
  if (!plan || !plan.width || !plan.height) return null;
  return { width: plan.width, height: plan.height };
};

FarmFocus.prototype._toggleRecord = async function (recBtn) {
  if (this.recording.active) {
    const rec = this.recording.recorder;
    this.recording.active = false;
    this.recording.recorder = null;
    if (this.recording.timer) { clearInterval(this.recording.timer); this.recording.timer = null; }
    const label = this.host.querySelector('[data-readout="record-label"]');
    const timer = this.host.querySelector('[data-readout="record-timer"]');
    if (label) label.textContent = 'Saving…';
    if (timer) timer.textContent = '';
    recBtn.classList.remove('recording');
    // Snapshot what this clip was recorded as before awaiting: focusing
    // another device mid-save runs `show` → `_resetRecording`, which
    // clears these slots out from under the resolved artifact.
    const naming = {
      settings:    this.recording.settings,
      plannedSize: this.recording.plannedSize,
      outputSize:  this.recording.outputSize,
    };
    try {
      const artifact = await rec.stop();
      this._onRecordFinished(artifact, naming);
    } catch (err) {
      this._onRecordError(err);
    }
    return;
  }

  if (!BrowserRecorder.isAvailable()) {
    this._onRecordError(new Error('MediaRecorder not available'));
    return;
  }
  const ctx = this._getRecorderContext();
  if (!ctx || !ctx.canvas) { this._onRecordError(new Error('no live canvas')); return; }
  // The size travels in the context alongside the DOM handles (see
  // FarmApp.getRecorderContext) so a re-focus mid-session can't strand
  // us on a stale selection; the local menu is the fallback for a
  // caller that doesn't supply one.
  const settings = ctx.settings || this.captureSettings();
  try {
    const rec = new BrowserRecorder({
      canvas:      ctx.canvas,
      frameImg:    ctx.frameImg,
      screen:      ctx.screen,
      overlayHost: ctx.overlayHost,
      fps: 60,
      // Belt and braces: `settings` is the new capture-size option and
      // the four handles above are the shape BrowserRecorder has always
      // taken. Both are passed so this works against the recorder as it
      // is today (which ignores `settings`) and against the resized one,
      // in either landing order.
      settings,
    });
    const planned = this._resolvedOutputSize();
    rec.start();
    this.recording.recorder = rec;
    this.recording.settings = settings || null;
    this.recording.plannedSize = planned;
    // `start()` builds the compose canvas the recording is sampled
    // from, so reading it back is the truth about the output size —
    // whichever BrowserRecorder build is loaded.
    this.recording.outputSize = composeCanvasSize(rec) || planned;
    this._onRecordStarted();
  } catch (err) {
    this._onRecordError(err);
  }
};

// FarmApp pumps per-tile telemetry here — keeps the gauges live
// without the focus pane needing its own ticker.
FarmFocus.prototype.updateTelemetry = function (t) {
  if (this.fpsEl && t.fps !== undefined) this.fpsEl.textContent = t.fps + ' fps';
  if (this.latEl && t.lat !== undefined) this.latEl.textContent = t.lat + ' ms';
  if (this.brEl  && t.br  !== undefined) this.brEl.textContent  = t.br  + ' kbps';
  // The live canvas only settles on its size once frames arrive, so
  // piggyback the readout on the telemetry tick rather than polling.
  this._renderCaptureDims();
};

FarmFocus.prototype._onRecordStarted = function () {
  this.recording.active = true;
  this.recording.startedAt = Date.now();
  if (this.recording.timer) clearInterval(this.recording.timer);
  this.recording.timer = setInterval(() => this._renderRecordTimer(), 250);
  this._renderRecordButton();
  this._renderRecordTimer();
};

FarmFocus.prototype._onRecordFinished = function (artifact, naming) {
  this._renderRecordButton();
  this._renderRecordTimer();
  if (!artifact || typeof artifact.url !== 'string') return;
  this.recording.entries.unshift({
    url: artifact.url,
    filename: this._recordFilename(artifact, naming),
    duration: typeof artifact.durationSeconds === 'number' ? artifact.durationSeconds : 0,
    bytes:    typeof artifact.bytes === 'number'           ? artifact.bytes           : 0,
  });
  this._renderRecordList();
};

// `download="…"` is what the file lands as, so the size belongs in the
// name. Two honesty rules: a recorder that ignored the chosen size gets
// its plain pixels rather than the preset it didn't honour, and a name
// the recorder already slugged is left alone instead of doubled.
FarmFocus.prototype._recordFilename = function (artifact, naming) {
  const base = (artifact && artifact.filename) || 'recording.webm';
  const n = naming || this.recording;
  const settings = n.settings;
  const out = n.outputSize;
  if (!settings || settings.size.isNative || !out) return base;
  const slug = sameSize(n.plannedSize, out)
    ? settings.slug(out.width, out.height)
    : out.width + 'x' + out.height;
  if (base.indexOf(slug) >= 0) return base;
  const dot = base.lastIndexOf('.');
  return dot > 0 ? base.slice(0, dot) + '-' + slug + base.slice(dot) : base + '-' + slug;
};

FarmFocus.prototype._onRecordError = function (err) {
  this.recording.active = false;
  this.recording.recorder = null;
  if (this.recording.timer) { clearInterval(this.recording.timer); this.recording.timer = null; }
  this._renderRecordButton();
  this._renderRecordTimer();
  if (err && err.message) console.warn('[FarmFocus] record error:', err.message);
};

FarmFocus.prototype._resetRecording = function () {
  if (this.recording.recorder) {
    try { this.recording.recorder.cancel(); } catch { /* ignore */ }
  }
  if (this.recording.timer) clearInterval(this.recording.timer);
  // Free Blob URLs the previous focus session created.
  (this.recording.entries || []).forEach((e) => {
    if (e.url && e.url.startsWith('blob:')) URL.revokeObjectURL(e.url);
  });
  this.recording = {
    recorder: null,
    active: false, startedAt: 0, timer: null,
    entries: [],
    settings: null, plannedSize: null, outputSize: null,
  };
  this._renderRecordButton();
  this._renderRecordTimer();
  this._renderRecordList();
};

FarmFocus.prototype._renderRecordButton = function () {
  const btn = this.host.querySelector('[data-action="toggle-record"]');
  const label = this.host.querySelector('[data-readout="record-label"]');
  if (!btn || !label) return;
  btn.classList.toggle('recording', this.recording.active);
  label.textContent = this.recording.active ? 'Stop' : 'Record';
};

FarmFocus.prototype._renderRecordTimer = function () {
  const el = this.host.querySelector('[data-readout="record-timer"]');
  if (!el) return;
  if (!this.recording.active) { el.textContent = ''; return; }
  const sec = (Date.now() - this.recording.startedAt) / 1000;
  el.textContent = formatDuration(sec);
};

FarmFocus.prototype._renderRecordList = function () {
  const host = this.host.querySelector('[data-readout="record-list"]');
  if (!host) return;
  host.innerHTML = this.recording.entries.map((e) => `
    <a href="${e.url}" download="${esc(e.filename)}" title="Download recording"
       style="display:flex;align-items:center;gap:6px;padding:6px 8px;border-radius:6px;background:rgba(255,255,255,0.04);border:1px solid rgba(255,255,255,0.08);color:inherit;font-size:11px;text-decoration:none">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="12" height="12"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
      <span>${esc(e.filename)}</span>
      <span style="margin-left:auto;color:var(--text-muted,#888);font-variant-numeric:tabular-nums">${formatDuration(e.duration)} · ${formatBytes(e.bytes)}</span>
    </a>`).join('');
};

FarmFocus.prototype.dispose = function () {
  this._resetRecording();
  if (this.captureMenu) { this.captureMenu.detach(); this.captureMenu = null; }
  this.host.innerHTML = '';
  FarmViews.renderFocusEmpty(this.host);
  this.tile = null;
  this.device = null;
};

// The recorder's compose canvas is the recording's output surface.
// Reading it back after `start()` is version-proof: a BrowserRecorder
// that resizes and one that doesn't both report what they really built.
function composeCanvasSize(rec) {
  const c = rec && rec.compose;
  return c && c.width > 0 && c.height > 0 ? { width: c.width, height: c.height } : null;
}

function sameSize(a, b) {
  return !!a && !!b && a.width === b.width && a.height === b.height;
}

function formatDuration(seconds) {
  if (!isFinite(seconds) || seconds < 0) seconds = 0;
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return m + ':' + String(s).padStart(2, '0');
}

function formatBytes(bytes) {
  if (!bytes || bytes < 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  let n = bytes, i = 0;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
  return n.toFixed(n < 10 && i ? 1 : 0) + ' ' + units[i];
}

function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, c =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
function shape(p) {
  return p === 'ipad' ? 'ipad' : p === 'tv' ? 'tv' : p === 'watch' ? 'watch' : '';
}

export { FarmFocus };
