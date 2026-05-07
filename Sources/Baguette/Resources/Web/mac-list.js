// macOS app list / screenshot view. Two URL shapes:
//   /mac                  → list every running app, click to open
//   /mac/<bundleID>       → focus view: live screenshot + control hints
// One self-contained IIFE that hangs `loadMacAppList` on `window`
// for symmetry with `sim-list.js`.
(function() {
  'use strict';

  const escapeHTML = (value) => String(value ?? '').replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[c]));

  const state = {
    apps: [],
    error: null,
    loading: false,
    focusBundleID: null,
  };

  function ensureShell() {
    if (document.getElementById('macRoot')) return;
    const root = document.createElement('div');
    root.id = 'macRoot';
    document.body.appendChild(root);
  }

  function installStyle() {
    if (document.getElementById('macStyle')) return;
    const style = document.createElement('style');
    style.id = 'macStyle';
    style.textContent = `
      .mac-card { margin: 20px; background: var(--panel); border: 1px solid var(--border); border-radius: 8px; overflow: hidden; }
      .mac-toolbar { display: flex; align-items: center; gap: 8px; padding: 16px 24px; border-bottom: 1px solid var(--border); }
      .mac-title { margin: 0; font-size: 16px; font-weight: 700; color: #1f2937; }
      .mac-sub { margin: 0; color: var(--text-muted); font-size: 12px; }
      .mac-spacer { flex: 1; }
      .mac-button { display: inline-flex; align-items: center; height: 30px; padding: 0 12px; border: 1px solid var(--border); border-radius: 8px; background: #f8fafc; color: #475569; font: inherit; font-size: 12px; font-weight: 700; cursor: pointer; text-decoration: none; }
      .mac-button:hover { background: #f1f5f9; border-color: #cbd5e1; }
      .mac-section-title { padding: 14px 20px 8px; font-size: 12px; font-weight: 800; letter-spacing: 0.02em; text-transform: uppercase; color: #1f2937; }
      .mac-table { width: 100%; border-collapse: collapse; }
      .mac-table th { height: 38px; padding: 0 20px; background: #f8fafc; color: var(--text-muted); font-size: 12px; font-weight: 700; letter-spacing: 0.02em; text-align: left; text-transform: uppercase; }
      .mac-table td { height: 50px; padding: 0 20px; border-top: 1px solid rgba(15,23,42,0.06); color: #64748b; font-size: 14px; }
      .mac-table td:first-child { color: #475569; font-weight: 700; }
      .mac-actions { text-align: right; white-space: nowrap; }
      .mac-empty, .mac-error { padding: 40px 24px; text-align: center; color: var(--text-muted); font-size: 14px; }
      .mac-error { color: var(--danger); }
      .mac-dot { display: inline-block; width: 6px; height: 6px; margin-right: 8px; border-radius: 99px; background: #94a3b8; vertical-align: 1px; }
      .mac-dot.active { background: var(--success); }
      .mac-screenshot { display: block; max-width: 100%; height: auto; border-radius: 8px; border: 1px solid var(--border); }
      .mac-hints { padding: 12px 20px; color: var(--text-muted); font: 11px monospace; background: #f8fafc; border-top: 1px solid var(--border); white-space: pre-wrap; }
    `;
    document.head.appendChild(style);
  }

  function parseFocusBundleID() {
    // /mac/<bundleID> — single segment after "mac".
    const parts = location.pathname.split('/').filter(Boolean);
    if (parts.length >= 2 && parts[0] === 'mac') {
      return decodeURIComponent(parts[1]);
    }
    return null;
  }

  async function fetchApps() {
    const response = await fetch('/mac.json', { cache: 'no-store' });
    if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
    const json = await response.json();
    return (json.active || []).concat(json.inactive || []);
  }

  function renderRows(apps) {
    return apps.map(a => `
      <tr>
        <td><span class="mac-dot ${a.active ? 'active' : ''}"></span>${escapeHTML(a.name)}</td>
        <td>${escapeHTML(a.bundleID)}</td>
        <td>${a.pid}</td>
        <td class="mac-actions">
          <a class="mac-button" href="/mac/${encodeURIComponent(a.bundleID)}">Open</a>
        </td>
      </tr>
    `).join('');
  }

  function renderList() {
    const root = document.getElementById('macRoot');
    if (!root) return;
    const body = state.loading
      ? '<div class="mac-empty">Loading running apps…</div>'
      : state.error
        ? `<div class="mac-error">${escapeHTML(state.error)}</div>`
        : !state.apps.length
          ? '<div class="mac-empty">No running apps reported.</div>'
          : `
            <div class="mac-section-title">Active</div>
            <table class="mac-table">
              <thead><tr><th>Name</th><th>Bundle ID</th><th>PID</th><th class="mac-actions">Actions</th></tr></thead>
              <tbody>${renderRows(state.apps.filter(a => a.active))}</tbody>
            </table>
            <div class="mac-section-title">Other</div>
            <table class="mac-table">
              <thead><tr><th>Name</th><th>Bundle ID</th><th>PID</th><th class="mac-actions">Actions</th></tr></thead>
              <tbody>${renderRows(state.apps.filter(a => !a.active))}</tbody>
            </table>
          `;

    root.innerHTML = `
      <div class="mac-card">
        <div class="mac-toolbar">
          <div>
            <h1 class="mac-title">macOS Apps</h1>
            <p class="mac-sub">Drive native macOS apps the same way you drive iOS simulators.</p>
          </div>
          <div class="mac-spacer"></div>
          <a class="mac-button" href="/simulators">← iOS Simulators</a>
          <button class="mac-button" id="macRefresh">Refresh</button>
        </div>
        ${body}
      </div>`;
  }

  function renderFocus(bundleID) {
    const root = document.getElementById('macRoot');
    if (!root) return;
    const enc = encodeURIComponent(bundleID);
    root.innerHTML = `
      <div class="mac-card">
        <div class="mac-toolbar">
          <div>
            <h1 class="mac-title">${escapeHTML(bundleID)}</h1>
            <p class="mac-sub">Snapshot of the frontmost window. Refreshes every 1s.</p>
          </div>
          <div class="mac-spacer"></div>
          <a class="mac-button" href="/mac">← Back to apps</a>
        </div>
        <div style="padding: 20px;">
          <img id="macScreenshot" class="mac-screenshot" alt="screenshot of ${escapeHTML(bundleID)}" />
        </div>
        <div class="mac-hints">CLI:    baguette mac screenshot --bundle-id ${escapeHTML(bundleID)} --out ./shot.jpg
        baguette mac describe-ui --bundle-id ${escapeHTML(bundleID)}
        baguette mac input --bundle-id ${escapeHTML(bundleID)}    # stdin JSON gestures
HTTP:   GET /mac/${enc}/screen.jpg[?quality=N&scale=N]
        GET /mac/${enc}/describe-ui[?x=N&y=N]
WS:     ws://${location.host}/mac/${enc}/stream?format=mjpeg|avcc</div>
      </div>`;

    // Refresh the screenshot every second; cache-busting query
    // string forces a new fetch.
    const img = document.getElementById('macScreenshot');
    const tick = () => {
      if (!img.isConnected) return;
      img.src = `/mac/${enc}/screen.jpg?t=${Date.now()}`;
    };
    tick();
    setInterval(tick, 1000);
  }

  async function loadMacAppList() {
    state.loading = true;
    state.error = null;
    renderList();
    try {
      state.apps = await fetchApps();
    } catch (error) {
      state.error = error.message || String(error);
    } finally {
      state.loading = false;
      renderList();
    }
  }

  document.addEventListener('click', event => {
    if (event.target.closest?.('#macRefresh')) loadMacAppList();
  });

  function boot() {
    ensureShell();
    installStyle();
    state.focusBundleID = parseFocusBundleID();
    if (state.focusBundleID) {
      renderFocus(state.focusBundleID);
    } else {
      loadMacAppList();
    }
  }

  window.loadMacAppList = loadMacAppList;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
  } else {
    boot();
  }
})();
