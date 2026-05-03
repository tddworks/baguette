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
(function () {
  'use strict';

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
    // → no carry-over. The timer keeps the live label in sync without
    // needing a per-frame redraw.
    this.recording = { active: false, startedAt: 0, timer: null, entries: [] };
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
        <button class="preset record-btn" data-action="toggle-record" style="margin-top:10px;width:100%" title="Record an MP4 (H.264 -c copy via ffmpeg)">
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

    // Recording toggle. The host (FarmApp) provides a sender that
    // drops the verb on the device's WS — FarmFocus stays decoupled
    // from FarmTile internals, so the same handler works whether the
    // tile is in thumbnail or full mode.
    this._sendRecord = callbacks.onRecord || (() => {});
    const recBtn = this.host.querySelector('[data-action="toggle-record"]');
    if (recBtn) {
      recBtn.onclick = () => {
        if (this.recording.active) {
          // Optimistic UI: hide the live timer immediately and swap
          // to "Saving…" — finish() runs on a detached task so the
          // record_finished frame may arrive a beat later.
          this.recording.active = false;
          if (this.recording.timer) { clearInterval(this.recording.timer); this.recording.timer = null; }
          const label = this.host.querySelector('[data-readout="record-label"]');
          const timer = this.host.querySelector('[data-readout="record-timer"]');
          if (label) label.textContent = 'Saving…';
          if (timer) timer.textContent = '';
          recBtn.classList.remove('recording');
          this._sendRecord('stop');
        } else {
          this._sendRecord('start');
        }
      };
    }
  };

  // FarmApp pumps per-tile telemetry here — keeps the gauges live
  // without the focus pane needing its own ticker.
  FarmFocus.prototype.updateTelemetry = function (t) {
    if (this.fpsEl && t.fps !== undefined) this.fpsEl.textContent = t.fps + ' fps';
    if (this.latEl && t.lat !== undefined) this.latEl.textContent = t.lat + ' ms';
    if (this.brEl  && t.br  !== undefined) this.brEl.textContent  = t.br  + ' kbps';
  };

  // Server-side recording lifecycle hooks. FarmApp routes WS text
  // frames here via the per-device session — `record_started` /
  // `record_finished` / `record_error`.
  FarmFocus.prototype.handleServerText = function (obj) {
    if (!obj || typeof obj.type !== 'string') return;
    switch (obj.type) {
      case 'record_started':  this._onRecordStarted();   break;
      case 'record_finished': this._onRecordFinished(obj); break;
      case 'record_error':    this._onRecordError(obj);  break;
      default: break;
    }
  };

  FarmFocus.prototype._onRecordStarted = function () {
    this.recording.active = true;
    this.recording.startedAt = Date.now();
    if (this.recording.timer) clearInterval(this.recording.timer);
    this.recording.timer = setInterval(() => this._renderRecordTimer(), 250);
    this._renderRecordButton();
    this._renderRecordTimer();
  };

  FarmFocus.prototype._onRecordFinished = function (obj) {
    this.recording.active = false;
    if (this.recording.timer) { clearInterval(this.recording.timer); this.recording.timer = null; }
    this._renderRecordButton();
    this._renderRecordTimer();
    if (obj && typeof obj.url === 'string') {
      this.recording.entries.unshift({
        url: obj.url,
        filename: obj.filename || 'recording.mp4',
        duration: typeof obj.duration === 'number' ? obj.duration : 0,
        bytes:    typeof obj.bytes === 'number'    ? obj.bytes    : 0,
      });
      this._renderRecordList();
    }
  };

  FarmFocus.prototype._onRecordError = function (_obj) {
    this.recording.active = false;
    if (this.recording.timer) { clearInterval(this.recording.timer); this.recording.timer = null; }
    this._renderRecordButton();
    this._renderRecordTimer();
  };

  FarmFocus.prototype._resetRecording = function () {
    if (this.recording.timer) { clearInterval(this.recording.timer); this.recording.timer = null; }
    this.recording = { active: false, startedAt: 0, timer: null, entries: [] };
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
      <a href="${e.url}" download="${esc(e.filename)}" title="Download MP4"
         style="display:flex;align-items:center;gap:6px;padding:6px 8px;border-radius:6px;background:rgba(255,255,255,0.04);border:1px solid rgba(255,255,255,0.08);color:inherit;font-size:11px;text-decoration:none">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="12" height="12"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
        <span>${esc(e.filename)}</span>
        <span style="margin-left:auto;color:var(--text-muted,#888);font-variant-numeric:tabular-nums">${formatDuration(e.duration)} · ${formatBytes(e.bytes)}</span>
      </a>`).join('');
  };

  FarmFocus.prototype.dispose = function () {
    if (this.recording.timer) { clearInterval(this.recording.timer); this.recording.timer = null; }
    this.recording = { active: false, startedAt: 0, timer: null, entries: [] };
    this.host.innerHTML = '';
    if (window.FarmViews) window.FarmViews.renderFocusEmpty(this.host);
    this.tile = null;
    this.device = null;
  };

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

  window.FarmFocus = FarmFocus;
})();
