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
      </div>`;

    // FarmApp re-parents the live canvas into `previewScreen` after
    // we return — that way the bezel toggle + chrome layout stay in
    // one place (tile.attach()) instead of being split across two
    // mounting paths. Here we only build the chrome.
    this.previewScreen = this.host.querySelector('[data-role="focus-screen"]');
    this.fpsEl = this.host.querySelector('[data-readout="fps"]');
    this.latEl = this.host.querySelector('[data-readout="lat"]');
    this.brEl  = this.host.querySelector('[data-readout="br"]');

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
  };

  // FarmApp pumps per-tile telemetry here — keeps the gauges live
  // without the focus pane needing its own ticker.
  FarmFocus.prototype.updateTelemetry = function (t) {
    if (this.fpsEl && t.fps !== undefined) this.fpsEl.textContent = t.fps + ' fps';
    if (this.latEl && t.lat !== undefined) this.latEl.textContent = t.lat + ' ms';
    if (this.brEl  && t.br  !== undefined) this.brEl.textContent  = t.br  + ' kbps';
  };

  FarmFocus.prototype.dispose = function () {
    this.host.innerHTML = '';
    if (window.FarmViews) window.FarmViews.renderFocusEmpty(this.host);
    this.tile = null;
    this.device = null;
  };

  function esc(s) {
    return String(s ?? '').replace(/[&<>"']/g, c =>
      ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
  function shape(p) {
    return p === 'ipad' ? 'ipad' : p === 'tv' ? 'tv' : p === 'watch' ? 'watch' : '';
  }

  window.FarmFocus = FarmFocus;
})();
