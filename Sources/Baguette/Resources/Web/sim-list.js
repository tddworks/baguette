// The device list — every device of every family, real or virtual, iOS or
// Android, from `/devices.json`; what each row offers comes from the
// device's abilities, never from which family it is.
(function() {
  'use strict';

  // sim-native.js owns the page when the URL is `/devices/<udid>`
  // and sets this flag synchronously at script-eval time. Bail out so
  // we don't paint the list shell underneath the focus-mode chrome.
  if (window.__baguetteNativeMode) {
    console.log('[ASC Pro] sim-list.js suspended (native mode)');
    return;
  }

  const escapeHTML = window.escapeHTML || (value => String(value ?? '').replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[c])));

  const state = {
    devices: [],    // every device, as `/devices.json` lists it
    search: '',
    platform: 'all',
    reality: 'all',
    os: 'all',
    loading: false,
    error: null,
    // Per-device transition state — id → 'boot' | 'shutdown'. Drives the
    // in-row "Booting…" / "Shutting down…" chip, so the table stays put.
    pending: Object.create(null)
  };

  function ensureShell() {
    if (document.getElementById('simListView') && document.getElementById('simPluginView')) return;

    const root = document.createElement('div');
    root.id = 'ascProSimulatorRoot';
    root.innerHTML = `
      <div id="simListView"></div>
      <div id="simPluginView" style="display:none"></div>`;
    document.body.appendChild(root);
  }

  function installStyle() {
    if (document.getElementById('ascProSimListStyle')) return;
    const style = document.createElement('style');
    style.id = 'ascProSimListStyle';
    style.textContent = `
      :root {
        --asc-sim-bg: #f8fafc;
        --asc-sim-panel: #ffffff;
        --asc-sim-muted: #94a3b8;
        --asc-sim-text: #334155;
        --asc-sim-strong: #1f2937;
        --asc-sim-border: #e2e8f0;
        --asc-sim-border-soft: #edf2f7;
        --asc-sim-accent: #0f766e;
        --asc-sim-danger: #b91c1c;
      }
      body { margin: 0; background: var(--asc-sim-bg); color: var(--asc-sim-text); }
      #ascProSimulatorRoot, #simListView, #simPluginView {
        font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        min-height: 100vh;
      }
      .asc-sim-card {
        margin: 20px;
        overflow: hidden;
        background: var(--asc-sim-panel);
        border: 1px solid var(--asc-sim-border);
        border-radius: 8px;
      }
      .asc-sim-toolbar {
        display: flex;
        align-items: center;
        gap: 8px;
        padding: 16px 24px;
        border-bottom: 1px solid var(--asc-sim-border);
      }
      .asc-sim-title { margin: 0; color: var(--asc-sim-strong); font-size: 16px; font-weight: 700; }
      .asc-sim-spacer { flex: 1; }
      .asc-sim-input, .asc-sim-select {
        height: 32px;
        border: 1px solid var(--asc-sim-border);
        border-radius: 6px;
        background: #f9fafb;
        color: var(--asc-sim-text);
        font: inherit;
        font-size: 13px;
      }
      .asc-sim-input { width: 210px; padding: 0 10px; }
      .asc-sim-select { min-width: 112px; padding: 0 10px; }
      .asc-sim-button {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        height: 30px;
        padding: 0 12px;
        border: 1px solid var(--asc-sim-border);
        border-radius: 8px;
        background: #f8fafc;
        color: #475569;
        font: inherit;
        font-size: 12px;
        font-weight: 700;
        cursor: pointer;
        text-decoration: none;
      }
      .asc-sim-button:hover { background: #f1f5f9; border-color: #cbd5e1; color: #475569; }
      .asc-sim-pending {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        height: 30px;
        padding: 0 12px;
        color: var(--asc-sim-muted);
        font-size: 12px;
        font-weight: 600;
        font-style: italic;
      }
      .asc-sim-section-title {
        padding: 14px 20px 8px;
        color: var(--asc-sim-strong);
        font-size: 12px;
        font-weight: 800;
        letter-spacing: 0.02em;
        text-transform: uppercase;
      }
      .asc-sim-table { width: 100%; border-collapse: collapse; table-layout: fixed; }
      .asc-sim-table th {
        height: 38px;
        padding: 0 20px;
        background: #f8fafc;
        color: var(--asc-sim-muted);
        font-size: 12px;
        font-weight: 700;
        letter-spacing: 0.02em;
        text-align: left;
        text-transform: uppercase;
      }
      .asc-sim-table td {
        height: 58px;
        padding: 0 20px;
        border-top: 1px solid var(--asc-sim-border-soft);
        color: #64748b;
        font-size: 14px;
        vertical-align: middle;
      }
      .asc-sim-table td:first-child { color: #475569; font-weight: 700; }
      .asc-sim-actions { text-align: right; white-space: nowrap; }
      .asc-sim-dot {
        display: inline-block;
        width: 6px;
        height: 6px;
        margin-right: 8px;
        border-radius: 99px;
        background: #94a3b8;
        vertical-align: 1px;
      }
      .asc-sim-dot.booted { background: var(--asc-sim-accent); }
      .asc-sim-kind { color: #64748b; }
      .asc-sim-badge {
        display: inline-flex; align-items: center; height: 22px; padding: 0 9px; margin-right: 6px;
        border: 1px solid #fde68a; border-radius: 99px; background: #fef3c7; color: #92400e;
        font-size: 11px; font-weight: 700;
      }
      .asc-sim-empty, .asc-sim-error {
        padding: 40px 24px;
        color: var(--asc-sim-muted);
        font-size: 14px;
        text-align: center;
      }
      .asc-sim-error { color: var(--asc-sim-danger); }
      @media (max-width: 760px) {
        .asc-sim-card { margin: 10px; }
        .asc-sim-toolbar { align-items: stretch; flex-wrap: wrap; gap: 8px; padding: 12px; }
        .asc-sim-title { flex-basis: 100%; }
        .asc-sim-spacer { display: none; }
        .asc-sim-input, .asc-sim-select { width: auto; flex: 1 1 140px; }
        .asc-sim-table { table-layout: auto; }
        .asc-sim-table th:nth-child(2), .asc-sim-table td:nth-child(2) { display: none; }
        .asc-sim-table th, .asc-sim-table td { padding: 10px 14px; height: auto; }
        .asc-sim-table td { line-height: 1.45; }
        .asc-sim-table td:first-child { width: 40%; white-space: normal; word-break: break-word; }
        .asc-sim-actions { padding-right: 12px; }
        .asc-sim-actions .asc-sim-button { padding: 0 10px; height: 28px; font-size: 11px; margin-left: 4px; }
      }
      @media (max-width: 440px) {
        .asc-sim-card { margin: 8px; }
        .asc-sim-table th, .asc-sim-table td { padding: 8px 10px; }
        .asc-sim-table th:nth-child(4), .asc-sim-table td:nth-child(4) { display: none; }
        .asc-sim-actions .asc-sim-button { padding: 0 8px; height: 26px; font-size: 10.5px; }
      }
    `;
    document.head.appendChild(style);
  }

  const DeviceFilter = window.Baguette._DeviceFilter;

  const PLATFORMS = { iOS: 'iOS', watchOS: 'watchOS', tvOS: 'tvOS', visionOS: 'visionOS', android: 'Android', macOS: 'macOS' };

  /** A `/devices.json` entry as a row: its kind flattened beside it. */
  function rowOf(device) {
    const kind = device.kind || {};
    return {
      id: device.id,
      name: device.name || device.id,
      platform: kind.platform || '',
      reality: kind.reality || '',
      model: kind.model || '',
      os: kind.os || '',
      state: device.state || '',
      reason: device.reason || '',
      abilities: device.abilities || [],
    };
  }

  /** What a device is, in a few words: "Simulator", "Emulator", or its model on a real one. */
  function kindLabel(device) {
    if (device.reality === 'simulated') return 'Simulator';
    if (device.reality === 'emulated') return 'Emulator';
    return device.model || 'Device';
  }

  function stateLabel(device) {
    switch (device.state) {
      case 'ready': return 'Running';
      case 'starting': return 'Starting';
      case 'off': return 'Off';
      case 'unavailable': return device.reason ? `Unavailable — ${device.reason}` : 'Unavailable';
      default: return device.state;
    }
  }

  /** The row's controls, from what the device can do. */
  function actionsOf(device) {
    const can = (ability) => device.abilities.includes(ability);
    const actions = [];
    if (device.state === 'ready' && can('screen')) {
      if (!can('touch')) actions.push('<span class="asc-sim-badge">View-only</span>');
      actions.push(`<a class="asc-sim-button" href="/devices/${encodeURIComponent(device.id)}">Open</a>`);
    }
    if (can('power')) {
      const verb = device.state === 'off' ? 'boot' : device.state === 'ready' ? 'shutdown' : null;
      if (verb) {
        actions.push(`<button type="button" class="asc-sim-button" data-sim-action="${verb}" data-sim-id="${escapeHTML(device.id)}">${verb === 'boot' ? 'Boot' : 'Shutdown'}</button>`);
      }
    }
    return actions.join(' ');
  }

  function renderRows(devices) {
    return devices.map(device => {
      const pending = state.pending[device.id];
      const actions = pending
        ? `<span class="asc-sim-pending">${escapeHTML(pendingLabel(pending))}</span>`
        : actionsOf(device);
      const os = device.os || PLATFORMS[device.platform] || device.platform;
      return `
        <tr>
          <td>${escapeHTML(device.name)}</td>
          <td class="asc-sim-kind">${escapeHTML(kindLabel(device))}</td>
          <td><span class="asc-sim-dot ${device.state === 'ready' ? 'booted' : ''}"></span>${escapeHTML(pending ? pendingLabel(pending) : stateLabel(device))}</td>
          <td>${escapeHTML(os)}</td>
          <td class="asc-sim-actions">${actions}</td>
        </tr>`;
    }).join('');
  }

  function pendingLabel(action) {
    if (action === 'boot') return 'Booting…';
    if (action === 'shutdown') return 'Shutting down…';
    return 'Working…';
  }

  function renderSection(title, devices) {
    if (!devices.length) return '';
    return `
      <div class="asc-sim-section-title">${escapeHTML(title)}</div>
      <table class="asc-sim-table">
        <thead><tr><th>Name</th><th>Kind</th><th>State</th><th>OS</th><th class="asc-sim-actions">Actions</th></tr></thead>
        <tbody>${renderRows(devices)}</tbody>
      </table>`;
  }

  function option(value, label, selected) {
    return `<option value="${escapeHTML(value)}" ${selected === value ? 'selected' : ''}>${escapeHTML(label)}</option>`;
  }

  function platformOptions() {
    const platforms = Array.from(new Set(state.devices.map(d => d.platform).filter(Boolean)));
    return [option('all', 'All Platforms', state.platform),
            ...platforms.map(p => option(p, PLATFORMS[p] || p, state.platform))].join('');
  }

  function realityOptions() {
    return [option('all', 'Real & Virtual', state.reality),
            option('real', 'Real Devices', state.reality),
            option('virtual', 'Simulators & Emulators', state.reality)].join('');
  }

  function osOptions() {
    return [option('all', 'All OS Versions', state.os),
            option('latest', 'Latest OS', state.os),
            ...DeviceFilter.osNames(state.devices).map(os => option(os, os, state.os))].join('');
  }

  function filteredDevices() {
    return new DeviceFilter({
      platform: state.platform, reality: state.reality, os: state.os, search: state.search,
    }).apply(state.devices);
  }

  function render() {
    const activeId = document.activeElement?.id;
    const selectionStart = document.activeElement?.selectionStart;
    const selectionEnd = document.activeElement?.selectionEnd;
    ensureShell();
    installStyle();
    const list = document.getElementById('simListView');
    if (!list) return;

    const devices = filteredDevices();
    // Running first; real devices before virtual ones within each.
    const order = (a, b) => (a.reality === 'physical' ? 0 : 1) - (b.reality === 'physical' ? 0 : 1);
    const running = devices.filter(d => d.state === 'ready' || d.state === 'starting').sort(order);
    const rest = devices.filter(d => d.state !== 'ready' && d.state !== 'starting').sort(order);
    const body = state.loading
      ? '<div class="asc-sim-empty">Loading devices...</div>'
      : state.error
        ? `<div class="asc-sim-error">${escapeHTML(state.error)}</div>`
        : devices.length
          ? `${renderSection('Running', running)}${renderSection('Available', rest)}`
          : '<div class="asc-sim-empty">No devices match these filters.</div>';

    list.innerHTML = `
      <div class="asc-sim-card">
        <div class="asc-sim-toolbar">
          <h1 class="asc-sim-title">Devices</h1>
          <div class="asc-sim-spacer"></div>
          <input class="asc-sim-input" id="ascSimSearch" type="search" value="${escapeHTML(state.search)}" placeholder="Search devices...">
          <select class="asc-sim-select" id="ascSimPlatform">${platformOptions()}</select>
          <select class="asc-sim-select" id="ascSimReality">${realityOptions()}</select>
          <select class="asc-sim-select" id="ascSimOS">${osOptions()}</select>
          <a class="asc-sim-button" id="ascSimFarm" href="/farm">Device Farm</a>
          <button class="asc-sim-button" id="ascSimRefresh">Refresh</button>
        </div>
        ${body}
      </div>`;

    if (activeId) {
      const nextActive = document.getElementById(activeId);
      if (nextActive) {
        nextActive.focus();
        if (typeof selectionStart === 'number' && typeof nextActive.setSelectionRange === 'function') {
          nextActive.setSelectionRange(selectionStart, selectionEnd);
        }
      }
    }
  }

  async function fetchDevices() {
    const response = await fetch('/devices.json', { cache: 'no-store' });
    if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
    const json = await response.json();
    return (json.devices || []).map(rowOf);
  }

  async function loadSimDeviceList() {
    // The full-card "Loading…" only on the first fetch (or after an error
    // wiped the list); later refreshes leave the table on screen.
    const initial = state.devices.length === 0;
    if (initial) state.loading = true;
    state.error = null;
    if (initial) render();
    try {
      state.devices = await fetchDevices();
    } catch (error) {
      state.error = error.message || String(error);
    } finally {
      state.loading = false;
      render();
    }
  }

  async function postPower(action, id) {
    // POST /devices/<id>/<action> — any device that can be turned on and off.
    const response = await fetch(
      `/devices/${encodeURIComponent(id)}/${encodeURIComponent(action)}`,
      { method: 'POST' }
    );
    if (!response.ok) throw new Error(`${action} failed: ${response.status}`);
  }

  /** Whether `id` has reached where `action` takes it. */
  function arrived(action, id) {
    const device = state.devices.find(d => d.id === id);
    if (!device) return action === 'shutdown';
    return action === 'boot' ? device.state === 'ready' : device.state === 'off';
  }

  async function handleAction(action, id) {
    if (action !== 'boot' && action !== 'shutdown') return;
    if (state.pending[id]) return;
    state.pending[id] = action;
    render();
    try {
      await postPower(action, id);
      // An emulator answers before it is up: keep the chip until the
      // list says it arrived, for up to a minute.
      for (let i = 0; i < 60; i++) {
        await loadSimDeviceList();
        if (arrived(action, id)) break;
        await new Promise(resolve => setTimeout(resolve, 1000));
      }
    } catch (error) {
      state.error = error.message || String(error);
    } finally {
      delete state.pending[id];
      render();
    }
  }

  document.addEventListener('input', event => {
    if (event.target?.id !== 'ascSimSearch') return;
    state.search = event.target.value;
    render();
  });

  document.addEventListener('change', event => {
    const field = { ascSimPlatform: 'platform', ascSimReality: 'reality', ascSimOS: 'os' }[event.target?.id];
    if (!field) return;
    state[field] = event.target.value;
    render();
  });

  document.addEventListener('click', event => {
    const refresh = event.target.closest?.('#ascSimRefresh');
    if (refresh) {
      loadSimDeviceList();
      return;
    }

    const button = event.target.closest?.('[data-sim-action]');
    if (!button) return;
    handleAction(button.dataset.simAction, button.dataset.simId);
  });

  window.loadSimDeviceList = loadSimDeviceList;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', loadSimDeviceList, { once: true });
  } else {
    loadSimDeviceList();
  }

  console.log('[baguette] device list loaded');
})();
