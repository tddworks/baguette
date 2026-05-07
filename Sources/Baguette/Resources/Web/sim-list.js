// ASC Pro Plugin UI - Simulator List
// Self-contained simulator browser backed by the local /api/sim/devices API.
(function() {
  'use strict';

  // sim-native.js owns the page when the URL is `/simulators/<udid>`
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
    devices: [],
    search: '',
    family: 'iphones',
    runtime: 'all',
    loading: false,
    error: null
  };

  function getServerUrl() {
    return window.DataProvider?._serverUrl || `${location.protocol}//${location.host}`;
  }

  function getSimAPI() {
    return `${getServerUrl()}/api/sim`;
  }

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
      }
      .asc-sim-button:hover { background: #f1f5f9; border-color: #cbd5e1; }
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
        .asc-sim-table th:nth-child(3), .asc-sim-table td:nth-child(3) { display: none; }
        .asc-sim-table th, .asc-sim-table td { padding: 10px 14px; height: auto; }
        .asc-sim-table td { line-height: 1.45; }
        .asc-sim-table td:first-child { width: 40%; white-space: normal; word-break: break-word; }
        .asc-sim-actions { padding-right: 12px; }
        .asc-sim-actions .asc-sim-button { padding: 0 10px; height: 28px; font-size: 11px; margin-left: 4px; }
      }
      @media (max-width: 440px) {
        .asc-sim-card { margin: 8px; }
        .asc-sim-table th, .asc-sim-table td { padding: 8px 10px; }
        .asc-sim-table th:nth-child(2), .asc-sim-table td:nth-child(2) { display: none; }
        .asc-sim-actions .asc-sim-button { padding: 0 8px; height: 26px; font-size: 10.5px; }
      }
    `;
    document.head.appendChild(style);
  }

  function normalizeDevice(device) {
    const id = device.id || device.udid || '';
    const stateValue = device.state || (device.isBooted ? 'Booted' : 'Shutdown');
    const runtime = device.displayRuntime || device.os || runtimeLabel(device.runtime || '');
    const isBooted = typeof device.isBooted === 'boolean'
      ? device.isBooted
      : String(stateValue).toLowerCase() === 'booted';
    return {
      id,
      name: device.name || 'Simulator',
      state: stateValue,
      runtime,
      isBooted,
      affordances: device.affordances || defaultAffordances(id, isBooted)
    };
  }

  function runtimeLabel(runtime) {
    return String(runtime || '')
      .replace('com.apple.CoreSimulator.SimRuntime.', '')
      .replace(/^iOS-/, 'iOS ')
      .replace(/-/g, '.');
  }

  function defaultAffordances(id, isBooted) {
    return isBooted
      ? { stream: `asc simulators stream --udid ${id}`, shutdown: `asc simulators shutdown --udid ${id}` }
      : { boot: `asc simulators boot --udid ${id}` };
  }

  function runtimeVersion(runtime) {
    const match = String(runtime || '').match(/(\d+(?:\.\d+)*)/);
    if (!match) return [0];
    return match[1].split('.').map(n => Number(n) || 0);
  }

  function compareVersions(a, b) {
    const av = runtimeVersion(a);
    const bv = runtimeVersion(b);
    const length = Math.max(av.length, bv.length);
    for (let i = 0; i < length; i++) {
      const diff = (av[i] || 0) - (bv[i] || 0);
      if (diff) return diff;
    }
    return 0;
  }

  function latestRuntime(devices) {
    return devices.reduce((latest, device) => compareVersions(device.runtime, latest) > 0 ? device.runtime : latest, '');
  }

  function filteredDevices() {
    const latest = latestRuntime(state.devices);
    const term = state.search.trim().toLowerCase();
    return state.devices.filter(device => {
      if (state.family === 'iphones' && !/^iphone\b/i.test(device.name)) return false;
      if (state.family === 'ipads' && !/^ipad\b/i.test(device.name)) return false;
      if (state.runtime === 'latest' && latest && device.runtime !== latest) return false;
      if (state.runtime !== 'latest' && state.runtime !== 'all' && device.runtime !== state.runtime) return false;
      if (term && !`${device.name} ${device.state} ${device.runtime} ${device.id}`.toLowerCase().includes(term)) return false;
      return true;
    });
  }

  function runtimeOptions() {
    const runtimes = Array.from(new Set(state.devices.map(d => d.runtime).filter(Boolean)))
      .sort((a, b) => compareVersions(b, a));
    return [
      `<option value="all" ${state.runtime === 'all' ? 'selected' : ''}>All Runtimes</option>`,
      `<option value="latest" ${state.runtime === 'latest' ? 'selected' : ''}>Latest Runtime</option>`,
      ...runtimes.map(runtime => `<option value="${escapeHTML(runtime)}" ${state.runtime === runtime ? 'selected' : ''}>${escapeHTML(runtime)}</option>`)
    ].join('');
  }

  function renderRows(devices) {
    return devices.map(device => {
      const actions = Object.keys(device.affordances || {})
        .filter(key => key !== 'listSimulators')
        .map(key => `<button class="asc-sim-button" data-sim-action="${escapeHTML(key)}" data-sim-id="${escapeHTML(device.id)}">${escapeHTML(actionLabel(key))}</button>`)
        .join(' ');
      return `
        <tr>
          <td>${escapeHTML(device.name)}</td>
          <td><span class="asc-sim-dot ${device.isBooted ? 'booted' : ''}"></span>${escapeHTML(device.state)}</td>
          <td>${escapeHTML(device.runtime)}</td>
          <td class="asc-sim-actions">${actions}</td>
        </tr>`;
    }).join('');
  }

  function actionLabel(key) {
    return key.replace(/([A-Z])/g, ' $1').replace(/^./, c => c.toUpperCase());
  }

  function renderSection(title, devices) {
    if (!devices.length) return '';
    return `
      <div class="asc-sim-section-title">${escapeHTML(title)}</div>
      <table class="asc-sim-table">
        <thead><tr><th>Name</th><th>State</th><th>Runtime</th><th class="asc-sim-actions">Actions</th></tr></thead>
        <tbody>${renderRows(devices)}</tbody>
      </table>`;
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
    const running = devices.filter(d => d.isBooted);
    const available = devices.filter(d => !d.isBooted);
    const body = state.loading
      ? '<div class="asc-sim-empty">Loading simulators...</div>'
      : state.error
        ? `<div class="asc-sim-error">${escapeHTML(state.error)}</div>`
        : devices.length
          ? `${renderSection('Running', running)}${renderSection('Available', available)}`
          : '<div class="asc-sim-empty">No simulators match these filters.</div>';

    list.innerHTML = `
      <div class="asc-sim-card">
        <div class="asc-sim-toolbar">
          <h1 class="asc-sim-title">iOS Simulators</h1>
          <div class="asc-sim-spacer"></div>
          <input class="asc-sim-input" id="ascSimSearch" type="search" value="${escapeHTML(state.search)}" placeholder="Search devices...">
          <select class="asc-sim-select" id="ascSimFamily">
            <option value="iphones" ${state.family === 'iphones' ? 'selected' : ''}>iPhones</option>
            <option value="ipads" ${state.family === 'ipads' ? 'selected' : ''}>iPads</option>
            <option value="all" ${state.family === 'all' ? 'selected' : ''}>All Devices</option>
          </select>
          <select class="asc-sim-select" id="ascSimRuntime">${runtimeOptions()}</select>
          <a class="asc-sim-button" href="/mac" style="text-decoration:none">macOS Apps →</a>
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
    // baguette serve exposes the list at /simulators.json, pre-split
    // into running/available. We fold them back into a flat array
    // because the IIFE renders its own RUNNING / AVAILABLE sections.
    const response = await fetch('/simulators.json', { cache: 'no-store' });
    if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
    const json = await response.json();
    const flat = (json.running || []).concat(json.available || []);
    return flat.map(normalizeDevice);
  }

  async function loadSimDeviceList() {
    state.loading = true;
    state.error = null;
    render();
    try {
      state.devices = await fetchDevices();
    } catch (error) {
      state.error = error.message || String(error);
    } finally {
      state.loading = false;
      render();
    }
  }

  async function postSimAction(action, id) {
    // POST /simulators/<udid>/<action> — UDID lives in the path,
    // body is empty. Matches the canonical /baguette serve route
    // table (no /api/ prefix, no payload).
    const response = await fetch(
      `/simulators/${encodeURIComponent(id)}/${encodeURIComponent(action)}`,
      { method: 'POST' }
    );
    if (!response.ok) throw new Error(`${action} failed: ${response.status}`);
  }

  async function handleAction(action, id) {
    const device = state.devices.find(d => d.id === id);
    if (!device) return;

    const handler = window.simAffordanceHandlers?.[action];
    if (handler) {
      handler(id, device.name, device);
      return;
    }

    if (action === 'boot' || action === 'shutdown') {
      state.loading = true;
      render();
      try {
        await postSimAction(action, id);
        await loadSimDeviceList();
      } catch (error) {
        state.error = error.message || String(error);
        state.loading = false;
        render();
      }
    }
  }

  document.addEventListener('input', event => {
    if (event.target?.id !== 'ascSimSearch') return;
    state.search = event.target.value;
    render();
  });

  document.addEventListener('change', event => {
    if (event.target?.id === 'ascSimFamily') {
      state.family = event.target.value;
      render();
    }
    if (event.target?.id === 'ascSimRuntime') {
      state.runtime = event.target.value;
      render();
    }
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
  window.simAffordanceHandlers = window.simAffordanceHandlers || {};

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', loadSimDeviceList, { once: true });
  } else {
    loadSimDeviceList();
  }

  console.log('[ASC Pro] sim-list.js loaded');
})();
