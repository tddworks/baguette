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
// simulator. See `docs/features/camera/README.md`.
//
// The source can also be an uploaded still image or a looping video
// instead of a live webcam: pick image/video, choose a file (POSTed to
// `/simulators/<udid>/camera-source`), then Start. The Mac side decodes
// and fits it into the same shared buffer, so the dylib is unchanged.

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
      this.source = 'webcam';      // 'webcam' | 'image' | 'video'
      this.uploaded = null;        // { kind, name } after a successful upload
      this._resumeOnReady = false; // resume streaming once a switched-to file uploads
      // Whether the user has asked for a stream and not yet asked to
      // stop. `phase` only says what the server has acknowledged, which
      // lags a Start by a round-trip — anything reacting to "are we
      // streaming?" in that window has to read the intent instead.
      this._wantsStreaming = false;
      // Bumped per upload (and whenever the selection moves out from
      // under one) so a slow earlier response can't overwrite a newer
      // pick — staging keeps a single replaceable slot per udid.
      this._uploadSeq = 0;
      this.phase = 'idle';
      this.fps = 0;
      this.fit = 'fit';
      this.mirror = false;
      this.lastError = null;
      this.cleanupRequired = false;
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
      this._wantsStreaming = false;
      this._resumeOnReady = false;
      this._uploadSeq++;  // strand any upload still in flight
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
        this._wantsStreaming = false;
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
        this.cleanupRequired = msg.cleanupRequired === true;
        this.fps = typeof msg.fps === 'number' ? msg.fps : 0;
        this.lastError = msg.ok === false ? (msg.error || 'unknown error') : null;
        // A refused start means the stream we asked for isn't coming.
        if (this.lastError) this._wantsStreaming = false;
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

      // Source row: webcam / image / video.
      const row0 = document.createElement('div');
      row0.setAttribute('style', ROW_STYLE);
      row0.appendChild(document.createTextNode('Source:'));
      const sourceSel = document.createElement('select');
      sourceSel.setAttribute('style', SELECT_STYLE);
      sourceSel.dataset.cameraSource = '1';
      // The adjacent "Source:" text isn't associated with the control,
      // so name it directly rather than with a `for`/`id` pair — a page
      // can host more than one panel, and ids would collide.
      sourceSel.setAttribute('aria-label', 'Camera source');
      [['webcam', 'Webcam'], ['image', 'Image file'], ['video', 'Video file']].forEach(([v, label]) => {
        const o = document.createElement('option');
        o.value = v; o.textContent = label;
        sourceSel.appendChild(o);
      });
      sourceSel.value = this.source;
      sourceSel.onchange = (ev) => this._onSourceChange(ev.target.value);
      row0.appendChild(sourceSel);
      this.host.appendChild(row0);

      // Device row (webcam only).
      const row1 = document.createElement('div');
      row1.setAttribute('style', ROW_STYLE);
      const select = document.createElement('select');
      select.setAttribute('style', SELECT_STYLE);
      select.dataset.cameraSelect = '1';
      select.setAttribute('aria-label', 'Webcam device');
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
      this._deviceRow = row1;

      // File row (image/video only): choose a file, upload it.
      const rowFile = document.createElement('div');
      rowFile.setAttribute('style', 'display:flex;flex-direction:column;align-items:stretch;gap:6px;padding:4px 0');
      const fileInput = document.createElement('input');
      fileInput.type = 'file';
      fileInput.accept = 'image/*';
      fileInput.style.display = 'none';
      fileInput.onchange = (ev) => {
        const f = ev.target.files && ev.target.files[0];
        if (f) this._uploadFile(f);
      };
      const chooseBtn = document.createElement('button');
      chooseBtn.type = 'button';
      chooseBtn.textContent = 'Choose file…';
      chooseBtn.setAttribute('style', BTN_STYLE + 'align-self:flex-start');
      chooseBtn.onclick = () => fileInput.click();
      const fileName = document.createElement('span');
      fileName.dataset.cameraFilename = '1';
      fileName.style.cssText = 'display:block;max-width:100%;font-size:11px;color:var(--text-muted,#94a3b8);overflow:hidden;text-overflow:ellipsis;white-space:nowrap';
      fileName.textContent = 'no file chosen';
      rowFile.appendChild(chooseBtn);
      rowFile.appendChild(fileName);
      rowFile.appendChild(fileInput);
      rowFile.style.display = 'none';
      this.host.appendChild(rowFile);
      this._fileRow = rowFile;
      this._fileInput = fileInput;

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
        toggle.textContent = this.cleanupRequired ? 'Retry stop' : 'Start';
      } else {
        status.style.color = 'var(--text-muted,#94a3b8)';
        status.textContent = 'idle';
        toggle.textContent = 'Start';
      }
    }

    _onSourceChange(value) {
      // Read the intent, not the acknowledged phase: a source changed
      // between Start and the server's `camera_state` would otherwise
      // look idle, so the old source would be left streaming and the
      // new one never started.
      const wasStreaming = this._wantsStreaming;
      this._resumeOnReady = false;
      this._uploadSeq++;  // a file uploading for the old source is now stale
      this.source = value;
      if (this._deviceRow) this._deviceRow.style.display = value === 'webcam' ? '' : 'none';
      if (this._fileRow) this._fileRow.style.display = value === 'webcam' ? 'none' : '';
      if (this._fileInput) this._fileInput.accept = value === 'video' ? 'video/*' : 'image/*';
      // A file staged for one kind doesn't carry over to the other.
      if (this.uploaded && this.uploaded.kind !== value) this.uploaded = null;
      this._renderFileName();

      // Switch live: stop the old stream and start the new source without a
      // manual Stop/Start. If the new source isn't ready (no file chosen yet),
      // resume automatically once one is uploaded.
      if (wasStreaming) {
        this._send({ type: 'camera_stop' });
        if (this._sourceReady()) {
          this._startCurrent();
        } else {
          // Still want a stream — just waiting on the file for it.
          this._resumeOnReady = true;
          this._wantsStreaming = true;
        }
      }
    }

    /** True when the current source has everything it needs to start. */
    _sourceReady() {
      if (this.source === 'webcam') return !!this.selectedUID;
      return !!(this.uploaded && this.uploaded.kind === this.source);
    }

    /** Send `camera_start` for the current source if it's ready. */
    _startCurrent() {
      if (this.cleanupRequired || !this._sourceReady()) return;
      this._wantsStreaming = true;
      if (this.source === 'webcam') {
        this._send({
          type: 'camera_start',
          source: 'webcam',
          deviceUID: this.selectedUID,
          fit: this.fit,
          mirror: this.mirror,
        });
      } else {
        this._send({
          type: 'camera_start',
          source: this.source,
          fit: this.fit,
          mirror: this.mirror,
        });
      }
    }

    _renderFileName() {
      if (!this.host) return;
      const el = this.host.querySelector('[data-camera-filename]');
      if (!el) return;
      el.textContent = this.uploaded ? this.uploaded.name : 'no file chosen';
    }

    async _uploadFile(file) {
      const status = this.host && this.host.querySelector('[data-camera-status]');
      const setStatus = (color, text) => {
        if (status) { status.style.color = color; status.textContent = text; }
      };
      // Uploads can overlap, and staging keeps one replaceable slot per
      // udid — so a slower earlier response must not land as the current
      // selection. Everything the response touches is gated on this
      // upload still being the one the panel is waiting for.
      const token = ++this._uploadSeq;
      const source = this.source;
      const udid = this.udid;
      const isStale = () =>
        token !== this._uploadSeq || source !== this.source || udid !== this.udid;

      setStatus('var(--text-muted,#94a3b8)', 'uploading ' + file.name + '…');
      try {
        const url = `/simulators/${encodeURIComponent(udid)}/camera-source?name=${encodeURIComponent(file.name)}`;
        const res = await fetch(url, { method: 'POST', body: file });
        const data = await res.json().catch(() => ({}));
        if (isStale()) return;
        if (!res.ok || !data.ok) {
          this.uploaded = null;
          setStatus('var(--danger,#b91c1c)', (data && data.error) || ('upload failed (' + res.status + ')'));
        } else {
          this.uploaded = { kind: data.kind, name: file.name };
          // If a live source-switch is waiting on this file, resume now;
          // otherwise just enable Start.
          if (this._resumeOnReady) {
            this._resumeOnReady = false;
            setStatus('var(--text-muted,#94a3b8)', 'starting…');
            this._startCurrent();
          } else {
            setStatus('var(--text-muted,#94a3b8)', 'ready — press Start');
          }
        }
      } catch (e) {
        if (isStale()) return;
        this.uploaded = null;
        setStatus('var(--danger,#b91c1c)', 'upload error');
      }
      this._renderFileName();
    }

    _onToggle() {
      if (this.phase === 'streaming' || this.cleanupRequired) {
        this._resumeOnReady = false;
        this._wantsStreaming = false;
        this._send({ type: 'camera_stop' });
        return;
      }
      this._startCurrent();
    }
  }

  window.CameraPanel = CameraPanel;
})();
