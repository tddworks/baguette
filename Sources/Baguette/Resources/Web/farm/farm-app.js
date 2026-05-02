// FarmApp — boot orchestrator for /farm.
//
// One instance, owns:
//   • device discovery (GET /simulators.json on boot + manual refresh)
//   • a Map<udid, FarmTile> with one tile per booted device
//   • filter state (FarmFilter)
//   • view mode + sort + selection
//   • event wiring on the rendered DOM (delegated, so renderers
//     stay pure)
//
// Render flow on every state change:
//   1. compute visible = filter.apply(devices)
//   2. FarmViews.renderRail / renderGridHead / renderCli (chrome)
//   3. FarmViews.renderGrid|Wall|List into #farm-view-host
//   4. for each tile in visible, find its `[data-screen-host]` and
//      tile.attach(host) — the canvas hops between hosts without the
//      WebSocket noticing.
//
// Tiles for un-booted devices are NOT instantiated. Booting flips
// `uiState` to "live" and triggers a fresh tile.start() on next
// render; shutdown stops the tile.
(function () {
  'use strict';

  const VIEW_HOST_ID = 'farm-view-host';

  function FarmApp() {
    this.devices = [];
    this.tiles = new Map();              // udid → FarmTile
    this.chromeLayouts = new Map();      // udid → layout|null (null = no chrome)
    this.filter = new window.FarmFilter();
    this.view = 'grid';
    this.sort = { key: 'name', dir: 'asc' };
    this.selectedUdid = null;
    this.focus = null;
    this.showBezels = true;
    this.fleetTelemetry = { live: 0, total: 0, fps: 0, bw: 0, lat: 0 };
  }

  FarmApp.prototype.boot = async function () {
    await this.refreshDevices();
    // Bezels are on by default — pre-fetch chrome layouts before the
    // first paint so tiles mount with their bezel chrome on the
    // initial render rather than flashing raw → bezel as layouts
    // arrive. Fetches run in parallel; failures are tolerated (Apple
    // TV / watchOS have no chrome bundle and DeviceFrame falls back
    // to a flat fill).
    if (this.showBezels) await this.loadChromeLayouts();
    this.renderAll();
    this.startVisibleTiles();
    this.bindGlobalKeys();
    this.startClock();
  };

  // ---- device discovery ---------------------------------------------
  FarmApp.prototype.refreshDevices = async function () {
    try {
      const res = await fetch('/simulators.json');
      const json = await res.json();
      const all = [...(json.running || []), ...(json.available || [])];
      this.devices = all.map(d => normalizeDevice(d));
      this.filter.seedRuntimes(uniq(this.devices.map(d => d.runtime)));
    } catch (e) {
      this.devices = [];
      console.error('[FarmApp] device fetch failed', e);
    }
  };

  // ---- render --------------------------------------------------------
  FarmApp.prototype.renderAll = function () {
    const visible = this.filter.apply(this.devices);
    const sorted = this.sortFor(this.view, visible);
    const ctx = this.renderCtx(sorted);

    window.FarmViews.renderHeader(byId('farm-header'), ctx);
    window.FarmViews.renderRail(byId('farm-rail'), ctx);
    window.FarmViews.renderGridHead(byId('farm-grid-head'), ctx);
    window.FarmViews.renderCli(byId('farm-cli'), ctx);

    const host = byId(VIEW_HOST_ID);
    if (this.view === 'grid') window.FarmViews.renderGrid(host, sorted, ctx);
    if (this.view === 'wall') window.FarmViews.renderWall(host, sorted, ctx);
    if (this.view === 'list') window.FarmViews.renderList(host, sorted, ctx);

    // Empty state for the focus pane on first render.
    if (!this.selectedUdid && !this.focus) {
      window.FarmViews.renderFocusEmpty(byId('farm-focus'));
    }

    this.bindAfterRender();
    this.attachTilesToScreens();
  };

  FarmApp.prototype.renderCtx = function (visible) {
    const counts = this.filter.counts(this.devices);
    const fleet = {
      live:  this.devices.filter(d => d.uiState === 'live').length,
      total: this.devices.length,
      fps:   this.fleetTelemetry.fps,
      bw:    this.fleetTelemetry.bw,
      lat:   this.fleetTelemetry.lat
    };
    return {
      filter: this.filter,
      view: this.view,
      sort: this.sort,
      visible: visible.length,
      total: this.devices.length,
      search: this.filter.search,
      runtimes: [...this.filter.runtimes].sort(),
      counts, fleet,
      display: { bezel: this.showBezels },
      selectedUdid: this.selectedUdid
    };
  };

  // ---- event wiring (post-render) -----------------------------------
  FarmApp.prototype.bindAfterRender = function () {
    // Filter checkboxes
    document.querySelectorAll('#farm-rail input[data-platform]').forEach(el =>
      el.onchange = () => { this.filter.toggle('platforms', el.dataset.platform); this.renderAll(); });
    document.querySelectorAll('#farm-rail input[data-state]').forEach(el =>
      el.onchange = () => { this.filter.toggle('states', el.dataset.state); this.renderAll(); });
    document.querySelectorAll('#farm-rail .runtime-pill').forEach(p =>
      p.onclick = () => { this.filter.toggle('runtimes', p.dataset.runtime); this.renderAll(); });

    // Display toggles (bezel, future: scanlines / crosshairs / grid pitch).
    document.querySelectorAll('#farm-rail input[data-display]').forEach(el =>
      el.onchange = () => this.toggleDisplay(el.dataset.display, el.checked));

    // Bulk actions
    document.querySelectorAll('#farm-rail [data-bulk]').forEach(b =>
      b.onclick = () => this.runBulk(b.dataset.bulk));

    // Search + view toggle
    const search = document.querySelector('#farm-grid-head [data-role="search"]');
    if (search) {
      search.oninput = () => { this.filter.search = search.value; this.renderAll(); search.focus(); };
    }
    document.querySelectorAll('#farm-grid-head [data-view]').forEach(b =>
      b.onclick = () => { this.view = b.dataset.view; this.renderAll(); });

    // List sort
    document.querySelectorAll('#farm-view-host .sortable').forEach(el =>
      el.onclick = () => {
        const key = el.dataset.key;
        if (this.sort.key === key) this.sort.dir = this.sort.dir === 'asc' ? 'desc' : 'asc';
        else { this.sort.key = key; this.sort.dir = 'asc'; }
        this.renderAll();
      });

    // Tile / row / panel click → select. Quick-action buttons inside
    // stop propagation so the tile click doesn't fight the action.
    document.querySelectorAll('#farm-view-host [data-udid]').forEach(node =>
      node.onclick = (e) => {
        if (e.target.closest('[data-action]')) return;
        this.select(node.dataset.udid);
      });
    document.querySelectorAll('#farm-view-host [data-action]').forEach(btn =>
      btn.onclick = (e) => {
        e.stopPropagation();
        const node = btn.closest('[data-udid]');
        if (node) this.runAction(node.dataset.udid, btn.dataset.action);
      });

    // CLI copy
    const copy = document.querySelector('#farm-cli .copy');
    if (copy) {
      copy.onclick = () => {
        const cmd = document.querySelector('#farm-cli .cmd')?.innerText || '';
        navigator.clipboard?.writeText(cmd.replace(/^\$\s*/, '').trim());
      };
    }
  };

  // ---- tiles ---------------------------------------------------------
  FarmApp.prototype.startVisibleTiles = function () {
    this.devices.forEach(d => {
      if (d.uiState === 'live' && !this.tiles.has(d.udid)) {
        const tile = new window.FarmTile({
          device: d,
          onTelemetry: (udid, t) => this.onTileTelemetry(udid, t)
        });
        this.tiles.set(d.udid, tile);
        tile.start();
      }
    });
    // Drop tiles whose device disappeared.
    for (const udid of [...this.tiles.keys()]) {
      if (!this.devices.find(d => d.udid === udid && d.uiState === 'live')) {
        this.tiles.get(udid).stop();
        this.tiles.delete(udid);
      }
    }
    this.attachTilesToScreens();
  };

  // After every render, walk the produced screen-host nodes and ask
  // each tile to install its canvas. Selection no longer affects the
  // grid — the focused tile's canvas keeps painting in its grid host
  // continuously, and the focus pane uses a separate mirror <video>
  // sourced from the same canvas's captureStream. One pipeline, two
  // viewers, no swaps.
  FarmApp.prototype.attachTilesToScreens = function () {
    document.querySelectorAll('#farm-view-host [data-screen-host]').forEach(host => {
      const udid = host.dataset.screenHost;
      const tile = this.tiles.get(udid);
      if (!tile) return;
      tile.attach(host, {
        useBezel: this.showBezels,
        layout:   this.chromeLayouts.get(udid) || null
      });
    });
  };

  // ---- bezel toggle --------------------------------------------------
  FarmApp.prototype.toggleDisplay = async function (kind, enabled) {
    if (kind !== 'bezel') return;
    this.showBezels = enabled;
    if (enabled) {
      await this.loadChromeLayouts();
    }
    this.renderAll();
  };

  // Lazy chrome-layout fetch — only paid for once the user actually
  // wants bezels. Hits `/simulators/<udid>/chrome.json` per device;
  // a 404 means DeviceKit has no chrome bundle (Apple TV, watchOS),
  // and DeviceFrame falls back to a flat fill in that case.
  FarmApp.prototype.loadChromeLayouts = async function () {
    const need = this.devices.filter(d =>
      d.uiState !== 'off' && !this.chromeLayouts.has(d.udid));
    await Promise.allSettled(need.map(async d => {
      try {
        const res = await fetch(`/simulators/${encodeURIComponent(d.udid)}/chrome.json`);
        if (!res.ok) { this.chromeLayouts.set(d.udid, null); return; }
        const layout = await res.json();
        this.chromeLayouts.set(d.udid, layout);
      } catch {
        this.chromeLayouts.set(d.udid, null);
      }
    }));
  };

  // ---- selection / focus --------------------------------------------
  FarmApp.prototype.select = function (udid) {
    if (this.selectedUdid === udid) return;
    if (this.selectedUdid) {
      const prev = this.tiles.get(this.selectedUdid);
      if (prev) prev.demote();
    }
    this.selectedUdid = udid;
    const device = this.devices.find(d => d.udid === udid);
    const tile = this.tiles.get(udid);
    if (!device) return;

    this.focus = this.focus || new window.FarmFocus(byId('farm-focus'));
    this.focus.show(device, tile, {
      onClose: () => this.clearFocus(),
      onOpenTab: (d) => window.open(`/simulators/${encodeURIComponent(d.udid)}`, '_blank'),
      onLifecycle: (d, action) => this.runAction(d.udid, action),
      onButton: (name) => tile?.button(name)
    });
    // Selection only affects two things — the highlight class on the
    // grid tile, and the focus pane content. The grid canvas keeps
    // painting in place; we install a mirror <video> in the focus
    // preview so the user sees the same frames at full size.
    this.applySelectionHighlight();
    const layout = this.chromeLayouts.get(udid) || null;
    if (tile && this.focus.previewScreen) {
      tile.attachMirror(this.focus.previewScreen, { useBezel: this.showBezels, layout });
    }
    // Bump stream quality + wire input on the mirror.
    if (tile) tile.promote({ layout });
  };

  // Flip the .selected class on grid tiles + refresh the CLI footer
  // (which carries the `--focus` arg). Header / rail / grid-head /
  // tile contents are untouched — no flicker.
  FarmApp.prototype.applySelectionHighlight = function () {
    document.querySelectorAll('#farm-view-host [data-udid]').forEach(node =>
      node.classList.toggle('selected', node.dataset.udid === this.selectedUdid));
    const ctx = this.renderCtx(this.filter.apply(this.devices));
    window.FarmViews.renderCli(byId('farm-cli'), ctx);
    const copy = document.querySelector('#farm-cli .copy');
    if (copy) {
      copy.onclick = () => {
        const cmd = document.querySelector('#farm-cli .cmd')?.innerText || '';
        navigator.clipboard?.writeText(cmd.replace(/^\$\s*/, '').trim());
      };
    }
  };

  FarmApp.prototype.clearFocus = function () {
    if (this.selectedUdid) {
      const tile = this.tiles.get(this.selectedUdid);
      if (tile) tile.demote();
    }
    this.selectedUdid = null;
    if (this.focus) { this.focus.dispose(); }
    this.applySelectionHighlight();
  };

  // ---- per-tile telemetry → fleet aggregate -------------------------
  FarmApp.prototype.onTileTelemetry = function (udid, t) {
    // Update the per-tile readouts in the live DOM without re-rendering.
    document.querySelectorAll(`#farm-view-host [data-udid="${cssEscape(udid)}"] [data-readout="fps"]`)
      .forEach(el => el.textContent = t.fps + ' fps');
    if (this.selectedUdid === udid && this.focus) {
      this.focus.updateTelemetry(t);
    }
    // Crude fleet roll-up: sum per-tile fps every second.
    let total = 0;
    this.tiles.forEach(tile => total += (tile.lastFps || 0));
    this.fleetTelemetry.fps = total;
    document.querySelectorAll('#farm-header [data-stat="fps"]').forEach(el => el.textContent = total);
  };

  // ---- actions -------------------------------------------------------
  FarmApp.prototype.runAction = async function (udid, action) {
    if (action === 'snapshot')  { this.tiles.get(udid)?.snapshot(); return; }
    if (action === 'reset')     { this.tiles.get(udid)?.forceIdr(); return; }
    if (action === 'open')      { window.open(`/simulators/${encodeURIComponent(udid)}`, '_blank'); return; }
    if (action === 'force-idr') { this.tiles.get(udid)?.forceIdr(); return; }
    if (action === 'boot')      { await this.lifecycle(udid, 'boot');     return; }
    if (action === 'shutdown')  { await this.lifecycle(udid, 'shutdown'); return; }
    if (action === 'restart')   {
      await this.lifecycle(udid, 'shutdown');
      await this.lifecycle(udid, 'boot');
      return;
    }
  };

  FarmApp.prototype.lifecycle = async function (udid, verb) {
    try {
      await fetch(`/simulators/${encodeURIComponent(udid)}/${verb}`, { method: 'POST' });
      await this.refreshDevices();
      this.startVisibleTiles();
      this.renderAll();
    } catch (e) {
      console.error(`[FarmApp] ${verb} failed`, e);
    }
  };

  FarmApp.prototype.runBulk = async function (kind) {
    const visible = this.filter.apply(this.devices);
    if (kind === 'snapshot') { visible.forEach(d => this.tiles.get(d.udid)?.snapshot()); return; }
    if (kind === 'reset')    { visible.forEach(d => this.tiles.get(d.udid)?.forceIdr()); return; }
    if (kind === 'boot' || kind === 'shutdown') {
      await Promise.allSettled(visible.map(d =>
        fetch(`/simulators/${encodeURIComponent(d.udid)}/${kind}`, { method: 'POST' })));
      await this.refreshDevices();
      this.startVisibleTiles();
      this.renderAll();
    }
  };

  // ---- sort (only meaningful for List view) -------------------------
  FarmApp.prototype.sortFor = function (mode, devices) {
    if (mode !== 'list') return devices;
    const { key, dir } = this.sort;
    const mul = dir === 'asc' ? 1 : -1;
    const get = d => ({
      name:    d.name.toLowerCase(),
      runtime: d.runtime,
      state:   d.uiState,
      fps:     this.tiles.get(d.udid)?.lastFps || 0,
      lat:     0,
      scale:   0
    }[key]);
    return [...devices].sort((a, b) => {
      const A = get(a), B = get(b);
      return A < B ? -mul : A > B ? mul : 0;
    });
  };

  // ---- misc ----------------------------------------------------------
  FarmApp.prototype.bindGlobalKeys = function () {
    document.addEventListener('keydown', e => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        document.querySelector('#farm-grid-head [data-role="search"]')?.focus();
      }
    });
  };

  FarmApp.prototype.startClock = function () {
    setInterval(() => {
      const t = new Date();
      const pad = n => String(n).padStart(2, '0');
      document.querySelectorAll('[data-stat="clock"]').forEach(el =>
        el.textContent = `${pad(t.getHours())}:${pad(t.getMinutes())}:${pad(t.getSeconds())}`);
    }, 1000);
  };

  // ---- helpers -------------------------------------------------------
  // CoreSimulator state strings → UI states. Booted defaults to "live"
  // because we open a thumbnail stream against every booted device.
  function normalizeDevice(d) {
    const platform = inferPlatform(d.name);
    let uiState = 'off';
    if (d.state === 'Booted')          uiState = 'live';
    else if (d.state === 'Booting')    uiState = 'boot';
    else if (d.state === 'Shutting Down') uiState = 'boot';
    else if (d.state === 'Shutdown')   uiState = 'off';
    return {
      udid: d.udid,
      name: d.name,
      runtime: d.runtime,
      state: d.state,
      platform,
      uiState
    };
  }

  function inferPlatform(name) {
    const n = name.toLowerCase();
    if (n.includes('ipad'))         return 'ipad';
    if (n.includes('apple tv'))     return 'tv';
    if (n.includes('apple watch'))  return 'watch';
    return 'iphone';
  }

  function uniq(xs) { return [...new Set(xs)]; }
  function byId(id) { return document.getElementById(id); }
  function cssEscape(s) { return (window.CSS?.escape ? CSS.escape(s) : s); }

  // Boot.
  window.FarmApp = FarmApp;
  document.addEventListener('DOMContentLoaded', () => {
    new FarmApp().boot();
  });
})();
