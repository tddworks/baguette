// sim-status-bar.js — status-bar override panel for the focus page.
//
// Hangs `window.StatusBarPanel` on the global so sim-native.js can
// surface a floating glass card that overrides the simulator's status
// bar (time, carrier, network, Wi-Fi / cellular signal, battery).
//
// The panel is a dumb sender: every control change debounces into a
// `POST /simulators/<udid>/status-bar` with the full override as JSON;
// "Clear overrides" sends `DELETE /simulators/<udid>/status-bar`. The
// Swift side owns all domain logic (`simctl status_bar` argv, range
// clamping). The live device stream shows the result — no client-side
// preview. See `docs/features/status-bar.md`.

(function () {
  'use strict';

  // Signal-bars SVG, `n` of `max` filled. Shared by the segmented
  // pickers; mirrors the toolbar glyph so the card reads as a set.
  function barsSVG(n, max) {
    const w = 16, gap = 2, bw = (w - gap * (max - 1)) / max, h = 12;
    let r = `<svg viewBox="0 0 ${w} ${h}" width="${max > 3 ? 17 : 15}" height="13" aria-hidden="true">`;
    for (let i = 0; i < max; i++) {
      const bh = 4 + (h - 4) * (i / (max - 1));
      r += `<rect x="${i * (bw + gap)}" y="${h - bh}" width="${bw}" height="${bh}" rx="1"
              fill="currentColor" opacity="${i < n ? 1 : 0.32}"/>`;
    }
    return r + '</svg>';
  }
  function wifiSVG(n) {
    const op = (k) => (k <= n ? 1 : 0.32);
    return `<svg viewBox="0 0 18 14" width="16" height="13" fill="none" stroke="currentColor"
      stroke-width="1.8" stroke-linecap="round" aria-hidden="true">
      <path d="M2 5.5A11 11 0 0 1 16 5.5" opacity="${op(3)}"/>
      <path d="M4.5 8A7 7 0 0 1 13.5 8" opacity="${op(2)}"/>
      <path d="M7 10.5A3 3 0 0 1 11 10.5" opacity="${op(1)}"/>
      <circle cx="9" cy="12.6" r="0.9" fill="currentColor" stroke="none" opacity="${op(1)}"/></svg>`;
  }

  const DATA_NETWORKS = [
    'wifi', '3g', '4g', 'lte', 'lte-a', 'lte+', '5g', '5g+', '5g-uwb', '5g-uc', 'hide',
  ];
  const NETWORK_LABELS = {
    wifi: 'Wi-Fi', '3g': '3G', '4g': '4G', lte: 'LTE', 'lte-a': 'LTE-A',
    'lte+': 'LTE+', '5g': '5G', '5g+': '5G+', '5g-uwb': '5G UWB', '5g-uc': '5G UC', hide: 'Hidden',
  };
  const WIFI_MODES = ['active', 'searching', 'failed'];
  const CELL_MODES = ['active', 'searching', 'failed', 'notSupported'];
  const BATTERY_STATES = ['charging', 'charged', 'discharging'];
  const BATTERY_LABELS = { charging: 'Charging', charged: 'Charged', discharging: 'Discharging' };
  const MODE_LABELS = {
    active: 'Active', searching: 'Searching', failed: 'Failed', notSupported: 'Not Supported',
  };

  class StatusBarPanel {
    constructor() {
      this.host = null;
      this.udid = null;
      this._timer = null;
      // Defaults mirror a healthy device; the panel never reads back
      // simctl state (there's no probe), so these are the starting
      // point until the user touches a control.
      this.state = {
        time: '',
        operatorName: 'Baguette',
        dataNetwork: '5g',
        wifiMode: 'active',
        wifiBars: 3,
        cellularMode: 'active',
        cellularBars: 4,
        batteryState: 'charged',
        batteryLevel: 100,
      };
    }

    /** @param {HTMLElement} host @param {string} udid */
    attach(host, udid) {
      if (!host || !udid) return;
      this.host = host;
      this.udid = udid;
      this._build();     // responsive immediately with defaults…
      this._hydrate();   // …then reflect the device's current overrides
    }

    // Read the simulator's current status-bar overrides and populate the
    // controls, so the panel shows what's actually on the device. Only
    // overridden fields come back; anything absent keeps its default.
    async _hydrate() {
      try {
        const res = await fetch(`/simulators/${encodeURIComponent(this.udid)}/status-bar`);
        if (!res.ok) return;
        const data = await res.json();
        Object.keys(data).forEach((k) => {
          if (k in this.state) this.state[k] = data[k];
        });
        if (this.host) this._build();
      } catch (e) { /* keep defaults */ }
    }

    detach() {
      if (this._timer) { clearTimeout(this._timer); this._timer = null; }
      if (this.host) { this.host.innerHTML = ''; this.host = null; }
    }

    // ---- view construction --------------------------------------

    _build() {
      const s = this.state;
      const sectionTitle = (t) => `<p class="sb-section-title">${t}</p>`;
      this.host.innerHTML =
        '<div class="sb-section">' +
          this._row('Time',
            `<input class="sb-field sb-time" data-k="time" type="text" placeholder="live"
               value="${escapeAttr(s.time)}" aria-label="Status bar time">
             <button class="sb-chip" data-act="apple-time">9:41</button>`) +
        '</div>' +
        '<div class="sb-section">' +
          this._row('Carrier',
            `<input class="sb-field" data-k="operatorName" type="text"
               value="${escapeAttr(s.operatorName)}" aria-label="Carrier name">`) +
          this._row('Network',
            `<select class="sb-field" data-k="dataNetwork" aria-label="Network type">` +
            DATA_NETWORKS.map((n) =>
              `<option value="${n}" ${n === s.dataNetwork ? 'selected' : ''}>${NETWORK_LABELS[n]}</option>`
            ).join('') + '</select>') +
        '</div>' +
        '<div class="sb-section">' + sectionTitle('Signal') +
          this._row('Cellular',
            this._modeSelect('cellularMode', CELL_MODES, s.cellularMode) +
            `<div class="sb-seg" data-seg="cellularBars" role="group" aria-label="Cellular bars"></div>`) +
          this._row('Wi-Fi',
            this._modeSelect('wifiMode', WIFI_MODES, s.wifiMode) +
            `<div class="sb-seg" data-seg="wifiBars" role="group" aria-label="Wi-Fi bars"></div>`) +
        '</div>' +
        '<div class="sb-section">' + sectionTitle('Battery') +
          this._row('State',
            `<div class="sb-pills" data-pills="batteryState">` +
            BATTERY_STATES.map((st) =>
              `<button class="sb-pill ${st === s.batteryState ? 'active' : ''}" data-s="${st}">${BATTERY_LABELS[st]}</button>`
            ).join('') + '</div>') +
          `<div class="sb-level-row">
             <input type="range" class="sb-range" data-k="batteryLevel" min="0" max="100"
               value="${s.batteryLevel}" aria-label="Battery level">
             <span class="sb-level-val">${s.batteryLevel}%</span>
           </div>` +
        '</div>' +
        '<div class="sb-section sb-footer">' +
          `<button class="sb-clear" data-act="clear">Clear overrides</button>` +
        '</div>';

      this._renderSeg('cellularBars', 4);
      this._renderSeg('wifiBars', 3);
      this._wire();
    }

    _row(label, control) {
      return `<div class="sb-row"><span class="sb-row-label">${label}</span>` +
             `<span class="sb-row-control">${control}</span></div>`;
    }

    _modeSelect(key, modes, selected) {
      return `<select class="sb-field sb-mode" data-k="${key}" aria-label="${key}">` +
        modes.map((m) =>
          `<option value="${m}" ${m === selected ? 'selected' : ''}>${MODE_LABELS[m]}</option>`
        ).join('') + '</select>';
    }

    _renderSeg(key, max) {
      const host = this.host.querySelector(`[data-seg="${key}"]`);
      if (!host) return;
      const cur = this.state[key];
      const glyph = key === 'wifiBars' ? wifiSVG : (i) => barsSVG(i, max);
      host.innerHTML = '';
      for (let i = 0; i <= max; i++) {
        const b = document.createElement('button');
        b.className = 'sb-seg-btn' + (i === cur ? ' active' : '');
        b.innerHTML = glyph(i, max);
        b.setAttribute('aria-label', `${i} bars`);
        b.onclick = () => {
          this.state[key] = i;
          host.querySelectorAll('.sb-seg-btn').forEach((c) => c.classList.remove('active'));
          b.classList.add('active');
          this._scheduleApply(key);
        };
        host.appendChild(b);
      }
    }

    // ---- event wiring -------------------------------------------

    _wire() {
      const h = this.host;
      h.querySelectorAll('input[data-k], select[data-k]').forEach((el) => {
        const key = el.getAttribute('data-k');
        const evt = el.tagName === 'SELECT' ? 'change' : 'input';
        el.addEventListener(evt, () => {
          if (key === 'batteryLevel') {
            this.state.batteryLevel = +el.value;
            const out = h.querySelector('.sb-level-val');
            if (out) out.textContent = this.state.batteryLevel + '%';
          } else {
            this.state[key] = el.value;
          }
          this._scheduleApply(key);
        });
      });

      const pills = h.querySelector('[data-pills="batteryState"]');
      if (pills) {
        pills.addEventListener('click', (e) => {
          const b = e.target.closest('.sb-pill');
          if (!b) return;
          this.state.batteryState = b.getAttribute('data-s');
          pills.querySelectorAll('.sb-pill').forEach((c) => c.classList.remove('active'));
          b.classList.add('active');
          this._scheduleApply('batteryState');
        });
      }

      const appleBtn = h.querySelector('[data-act="apple-time"]');
      if (appleBtn) appleBtn.onclick = () => {
        this.state.time = '9:41';
        const f = h.querySelector('[data-k="time"]');
        if (f) f.value = '9:41';
        this._scheduleApply('time');
      };

      const clearBtn = h.querySelector('[data-act="clear"]');
      if (clearBtn) clearBtn.onclick = () => this.clear();
    }

    // ---- network --------------------------------------------------

    // Coalesce rapid changes (slider drags, typing) and remember which
    // fields changed, then POST ONLY those. simctl merges, so sending a
    // single field updates just that indicator — changing Wi-Fi bars
    // sends `{wifiBars}` alone and never disturbs the data-network type
    // (so it can't flash "5G"), the battery, or anything else.
    _scheduleApply(key) {
      if (!key) return;
      if (!this._dirty) this._dirty = new Set();
      this._dirty.add(key);
      if (this._timer) clearTimeout(this._timer);
      this._timer = setTimeout(() => this._apply(), 250);
    }

    _apply() {
      if (!this.udid || !this._dirty || !this._dirty.size) return;
      const s = this.state;
      const body = {};
      this._dirty.forEach((k) => {
        if (k === 'time') {
          // An empty time string would make simctl reject the call.
          const t = s.time && s.time.trim();
          if (t) body.time = t;
        } else {
          body[k] = s[k];
        }
      });
      this._dirty = new Set();
      if (!Object.keys(body).length) return;

      fetch(`/simulators/${encodeURIComponent(this.udid)}/status-bar`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      }).catch((e) => console.warn('[status-bar] override failed', e));
    }

    clear() {
      if (this.udid) {
        fetch(`/simulators/${encodeURIComponent(this.udid)}/status-bar`, { method: 'DELETE' })
          .catch((e) => console.warn('[status-bar] clear failed', e));
      }
      // Reset the controls to defaults so the card matches the now-live
      // status bar.
      Object.assign(this.state, {
        time: '', operatorName: 'Carrier', dataNetwork: '5g',
        wifiMode: 'active', wifiBars: 3, cellularMode: 'active', cellularBars: 4,
        batteryState: 'charged', batteryLevel: 100,
      });
      if (this.host) this._build();
    }
  }

  function escapeAttr(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }

  window.StatusBarPanel = StatusBarPanel;
})();
