// sim-camera.js — camera-picker panel for the simulator pages.
//
// Hangs `window.CameraPanel` on the global so the focus-mode page
// (sim-native.js) and the sidebar page (sim-stream.js) can both
// surface a small camera-control card. UX echoes SimCamMac's HUD:
// device list + Start/Stop + Fit/Fill + Mirror + a live FPS readout.
//
// One panel per host element. Opens its own WebSocket to
// `/simulators/<udid>/camera`; closing the panel (or the page) tears
// the socket down. The Mac side enumerates AVCaptureDevices and
// pumps the chosen camera's BGRA frames into `/tmp/SimCam.bgra` — a
// shared-memory ring buffer the VirtualCamera dylib reads inside the
// simulator. See `docs/features/camera.md`.

(function () {
  'use strict';

  function escapeHTML(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }

  const ROW_STYLE = 'display:flex;align-items:center;gap:6px;padding:4px 0';
  const BTN_STYLE =
    'padding:3px 9px;font-size:11px;font-family:inherit;' +
    'background:transparent;border:1px solid var(--border,#e5e7eb);' +
    'border-radius:4px;cursor:pointer;color:inherit;';
  const SELECT_STYLE =
    'flex:1;padding:3px 6px;font-size:11px;font-family:inherit;' +
    'background:transparent;border:1px solid var(--border,#e5e7eb);' +
    'border-radius:4px;color:inherit;outline:none;';

  class CameraPanel {
    constructor() {
      this.host = null;
      this.ws = null;
      this.devices = [];
      this.selectedUID = null;
      this.phase = 'idle';
      this.fps = 0;
      this.fit = 'fit';
      this.mirror = false;
      this.lastError = null;
      // Optional callback: `(phase) => void`. Set by callers that
      // want to surface the camera state outside the panel — e.g.
      // the focus-mode toolbar lights a streaming dot on its
      // camera button regardless of whether the sheet is open.
      this.onPhaseChange = null;
    }

    /**
     * @param {HTMLElement} host
     * @param {string} udid
     */
    attach(host, udid) {
      if (!host || !udid) return;
      this.host = host;
      this.udid = udid;
      this._buildShell();
      this._openSocket();
    }

    detach() {
      if (this.ws) {
        try { this.ws.close(); } catch (e) {}
        this.ws = null;
      }
      if (this.host) { this.host.innerHTML = ''; this.host = null; }
      const prevPhase = this.phase;
      this.phase = 'idle';
      if (prevPhase !== 'idle' && typeof this.onPhaseChange === 'function') {
        try { this.onPhaseChange('idle'); } catch (_) { /* ignore */ }
      }
    }

    // --- WS ---

    _openSocket() {
      const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
      const url = `${proto}//${location.host}/simulators/${encodeURIComponent(this.udid)}/camera`;
      const ws = new WebSocket(url);
      this.ws = ws;
      ws.onmessage = (ev) => this._onMessage(ev);
      ws.onclose = () => {
        this.phase = 'idle';
        this._renderStatus();
      };
    }

    _send(obj) {
      if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
      this.ws.send(JSON.stringify(obj));
    }

    _onMessage(ev) {
      let msg;
      try { msg = JSON.parse(ev.data); } catch (e) { return; }
      if (msg.type === 'camera_devices') {
        this.devices = Array.isArray(msg.devices) ? msg.devices : [];
        if (!this.selectedUID) {
          const def = this.devices.find((d) => d.isDefault) || this.devices[0];
          if (def) this.selectedUID = def.uid;
        }
        this._renderDeviceList();
      } else if (msg.type === 'camera_state') {
        const prevPhase = this.phase;
        this.phase = msg.phase || 'idle';
        this.fps = typeof msg.fps === 'number' ? msg.fps : 0;
        this.lastError = msg.ok === false ? (msg.error || 'unknown error') : null;
        this._renderStatus();
        if (prevPhase !== this.phase && typeof this.onPhaseChange === 'function') {
          try { this.onPhaseChange(this.phase); } catch (_) { /* ignore */ }
        }
      }
    }

    // --- DOM ---

    _buildShell() {
      this.host.innerHTML = '';
      this.host.style.cssText = 'display:flex;flex-direction:column;gap:6px;';

      // Device row.
      const row1 = document.createElement('div');
      row1.setAttribute('style', ROW_STYLE);
      const select = document.createElement('select');
      select.setAttribute('style', SELECT_STYLE);
      select.dataset.cameraSelect = '1';
      select.onchange = (ev) => { this.selectedUID = ev.target.value; };
      row1.appendChild(select);
      const refresh = document.createElement('button');
      refresh.type = 'button';
      refresh.textContent = '↻';
      refresh.title = 'Refresh devices';
      refresh.setAttribute('style', BTN_STYLE);
      refresh.onclick = () => this._send({ type: 'camera_list' });
      row1.appendChild(refresh);
      this.host.appendChild(row1);

      // Start/Stop + status.
      const row2 = document.createElement('div');
      row2.setAttribute('style', ROW_STYLE);
      const toggle = document.createElement('button');
      toggle.type = 'button';
      toggle.dataset.cameraToggle = '1';
      toggle.textContent = 'Start';
      toggle.setAttribute('style', BTN_STYLE + 'min-width:54px');
      toggle.onclick = () => this._onToggle();
      row2.appendChild(toggle);

      const status = document.createElement('span');
      status.dataset.cameraStatus = '1';
      status.style.cssText = 'font-size:11px;color:var(--text-muted);flex:1';
      status.textContent = 'idle';
      row2.appendChild(status);
      this.host.appendChild(row2);

      // Fit + Mirror.
      const row3 = document.createElement('div');
      row3.setAttribute('style', ROW_STYLE);
      const fitLabel = document.createElement('label');
      fitLabel.style.cssText = 'font-size:11px;display:flex;align-items:center;gap:4px';
      const fitSel = document.createElement('select');
      fitSel.setAttribute('style', BTN_STYLE);
      ['fit', 'fill'].forEach((v) => {
        const o = document.createElement('option');
        o.value = v; o.textContent = v;
        fitSel.appendChild(o);
      });
      fitSel.value = this.fit;
      fitSel.onchange = (ev) => {
        this.fit = ev.target.value;
        this._send({ type: 'camera_set_flags', fit: this.fit, mirror: this.mirror });
      };
      fitLabel.appendChild(document.createTextNode('Fit:'));
      fitLabel.appendChild(fitSel);
      row3.appendChild(fitLabel);

      const mirrorLabel = document.createElement('label');
      mirrorLabel.style.cssText = 'font-size:11px;display:flex;align-items:center;gap:4px';
      const mirrorChk = document.createElement('input');
      mirrorChk.type = 'checkbox';
      mirrorChk.checked = this.mirror;
      mirrorChk.onchange = (ev) => {
        this.mirror = ev.target.checked;
        this._send({ type: 'camera_set_flags', fit: this.fit, mirror: this.mirror });
      };
      mirrorLabel.appendChild(mirrorChk);
      mirrorLabel.appendChild(document.createTextNode('Mirror'));
      row3.appendChild(mirrorLabel);
      this.host.appendChild(row3);
    }

    _renderDeviceList() {
      if (!this.host) return;
      const select = this.host.querySelector('[data-camera-select]');
      if (!select) return;
      select.innerHTML = '';
      if (this.devices.length === 0) {
        const o = document.createElement('option');
        o.value = ''; o.textContent = 'No cameras detected';
        select.appendChild(o);
        select.disabled = true;
        return;
      }
      select.disabled = false;
      this.devices.forEach((d) => {
        const o = document.createElement('option');
        o.value = d.uid;
        o.textContent = d.name + (d.isDefault ? ' (default)' : '');
        select.appendChild(o);
      });
      if (this.selectedUID) select.value = this.selectedUID;
    }

    _renderStatus() {
      if (!this.host) return;
      const status = this.host.querySelector('[data-camera-status]');
      const toggle = this.host.querySelector('[data-camera-toggle]');
      if (!status || !toggle) return;
      if (this.phase === 'streaming') {
        status.style.color = 'var(--success,#0f766e)';
        status.textContent = `streaming · ${this.fps.toFixed(1)} fps`;
        toggle.textContent = 'Stop';
      } else if (this.lastError) {
        status.style.color = 'var(--danger,#b91c1c)';
        status.textContent = this.lastError;
        toggle.textContent = 'Start';
      } else {
        status.style.color = 'var(--text-muted,#94a3b8)';
        status.textContent = 'idle';
        toggle.textContent = 'Start';
      }
    }

    _onToggle() {
      if (this.phase === 'streaming') {
        this._send({ type: 'camera_stop' });
      } else if (this.selectedUID) {
        this._send({
          type: 'camera_start',
          deviceUID: this.selectedUID,
          fit: this.fit,
          mirror: this.mirror,
        });
      }
    }
  }

  window.CameraPanel = CameraPanel;
})();
