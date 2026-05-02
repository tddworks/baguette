// FarmViews — pure DOM renderers for the device-farm UI.
//
// Every function takes a host element + the bits of state it needs
// and writes DOM. No fetches, no WebSockets, no global state — those
// belong to FarmApp. Each render function is idempotent; FarmApp
// re-runs them when state changes (filter, view toggle, selection).
//
// Tile / panel / row markup leaves a `data-screen-host` attribute on
// the placeholder where the live <canvas> lives. FarmApp asks each
// FarmTile to attach its canvas into that node after the view renders
// — that way the renderers stay pure and the streams aren't torn down
// every time the user types in the search box.
(function () {
  'use strict';

  // ---- header --------------------------------------------------------
  function renderHeader(host, ctx) {
    host.innerHTML = `
      <div class="brand">
        <div class="mark"><em>Baguette</em></div>
        <div class="sub">DEVICE&nbsp;FARM</div>
      </div>
      <div class="telemetry-bar">
        <div class="stat">
          <div class="label">Fleet</div>
          <div class="value"><span data-stat="live">${ctx.fleet.live}</span><span class="unit">/ ${ctx.fleet.total} ONLINE</span></div>
        </div>
        <div class="stat live">
          <div class="label">Aggregate FPS</div>
          <div class="value"><span data-stat="fps">${ctx.fleet.fps}</span><span class="unit">fps</span></div>
        </div>
        <div class="stat warn">
          <div class="label">Bandwidth</div>
          <div class="value"><span data-stat="bw">${ctx.fleet.bw.toFixed(1)}</span><span class="unit">Mb/s</span></div>
        </div>
        <div class="stat cyan">
          <div class="label">P50 Latency</div>
          <div class="value"><span data-stat="lat">${ctx.fleet.lat}</span><span class="unit">ms</span></div>
        </div>
      </div>
      <div class="sys-clock">
        <span class="led"></span>
        <time data-stat="clock">--:--:--</time>
      </div>`;
  }

  // ---- left rail -----------------------------------------------------
  function renderRail(host, ctx) {
    const platforms = [
      { key: 'iphone', label: 'iPhone' },
      { key: 'ipad',   label: 'iPad' },
      { key: 'watch',  label: 'Apple Watch' },
      { key: 'tv',     label: 'Apple TV' }
    ];
    const states = [
      { key: 'live',  label: 'Live stream' },
      { key: 'boot',  label: 'Booting' },
      { key: 'idle',  label: 'Booted · Idle' },
      { key: 'off',   label: 'Shutdown' },
      { key: 'error', label: 'Errored' }
    ];

    host.innerHTML = `
      <section>
        <h3>Platform</h3>
        ${platforms.map(p => `
          <label class="filter">
            <input type="checkbox" data-platform="${p.key}" ${ctx.filter.platforms.has(p.key) ? 'checked' : ''}>
            <span class="name">${p.label}</span>
            <span class="count">${ctx.counts.platform[p.key] || 0}</span>
          </label>`).join('')}
      </section>

      <section>
        <h3>Runtime</h3>
        <div class="runtime-pills">
          ${ctx.runtimes.map(r => `
            <span class="runtime-pill ${ctx.filter.runtimes.has(r) ? 'active' : ''}" data-runtime="${r}">
              <span class="dot"></span>${r}
            </span>`).join('')}
        </div>
      </section>

      <section>
        <h3>Status</h3>
        ${states.map(s => `
          <label class="filter">
            <input type="checkbox" data-state="${s.key}" ${ctx.filter.states.has(s.key) ? 'checked' : ''}>
            <span class="name">${s.label}</span>
            <span class="count">${ctx.counts.state[s.key] || 0}</span>
          </label>`).join('')}
      </section>

      <section>
        <h3>Bulk Action</h3>
        <button class="bulk-btn" data-bulk="boot"><span>Boot Filtered</span><span class="glyph">↗</span></button>
        <button class="bulk-btn" data-bulk="snapshot"><span>Snapshot All</span><span class="glyph">⌘ S</span></button>
        <button class="bulk-btn" data-bulk="reset"><span>Reset Streams</span><span class="glyph">⌥ R</span></button>
        <button class="bulk-btn danger" data-bulk="shutdown"><span>Shutdown Filtered</span><span class="glyph">⇧ X</span></button>
      </section>`;
  }

  // ---- grid head (count, search, view toggle) -----------------------
  function renderGridHead(host, ctx) {
    host.innerHTML = `
      <div class="title">
        <div class="num">${ctx.visible}</div>
        <div class="of">/ ${ctx.total}</div>
        <div class="lab">Devices&nbsp;&nbsp;visible</div>
      </div>
      <div class="grid-tools">
        <div class="search">
          <span class="ic">⌕</span>
          <input data-role="search" placeholder="Search by name, runtime, group…" value="${ctx.search}">
          <kbd>⌘ K</kbd>
        </div>
        <div class="view-toggle">
          <button data-view="grid" ${ctx.view === 'grid' ? 'class="active"' : ''}>Grid</button>
          <button data-view="wall" ${ctx.view === 'wall' ? 'class="active"' : ''}>Wall</button>
          <button data-view="list" ${ctx.view === 'list' ? 'class="active"' : ''}>List</button>
        </div>
      </div>`;
  }

  // ---- grid view -----------------------------------------------------
  function renderGrid(host, devices, ctx) {
    host.innerHTML = `<div class="grid"></div>`;
    const grid = host.firstChild;
    devices.forEach((d, i) => {
      const tile = document.createElement('article');
      tile.className = 'tile' + (ctx.selectedUdid === d.udid ? ' selected' : '');
      tile.dataset.udid = d.udid;
      tile.style.animationDelay = (i * 24) + 'ms';
      tile.innerHTML = `
        <span class="reg tl"></span><span class="reg tr"></span>
        <span class="reg bl"></span><span class="reg br"></span>
        <div class="tile-head">
          <div>
            <h3 class="tile-name">${escapeHTML(d.name)}</h3>
            <div class="tile-udid">${d.udid.slice(0, 8)}··· · ${escapeHTML(d.runtime)}</div>
          </div>
          <span class="tile-status" data-state="${d.uiState}">
            <span class="led"></span>${stateLabel(d.uiState)}
          </span>
        </div>
        <div class="tile-quick">
          <button class="qa" data-action="snapshot" title="Snapshot">◉</button>
          <button class="qa" data-action="reset" title="Force IDR">↻</button>
          <button class="qa" data-action="open" title="Open in tab">↗</button>
        </div>
        <div class="screen ${shapeFor(d.platform)}" data-screen-host="${d.udid}">
          ${overlayFor(d)}
        </div>
        <div class="tile-readout">
          <div class="col"><div class="k">FPS</div><div class="v ${d.uiState === 'live' ? 'lime' : 'dim'}" data-readout="fps">${d.uiState === 'live' ? '—' : '—'}</div></div>
          <div class="col"><div class="k">Lat</div><div class="v ${d.uiState === 'live' ? 'amber' : 'dim'}" data-readout="lat">—</div></div>
          <div class="col"><div class="k">Scale</div><div class="v" data-readout="scale">—</div></div>
        </div>`;
      grid.appendChild(tile);
    });
  }

  // ---- wall view -----------------------------------------------------
  function renderWall(host, devices, ctx) {
    host.innerHTML = `<div class="wall"></div>`;
    const wall = host.firstChild;
    devices.forEach((d, i) => {
      const panel = document.createElement('div');
      panel.className = 'panel ' + shapeFor(d.platform) + (ctx.selectedUdid === d.udid ? ' selected' : '');
      panel.dataset.udid = d.udid;
      panel.dataset.state = d.uiState;
      const channel = String(i + 1).padStart(2, '0');
      panel.innerHTML = `
        <div data-screen-host="${d.udid}" style="position:absolute;inset:0">${overlayFor(d, true)}</div>
        <span class="corner tl">${stateLabel(d.uiState).slice(0, 4)} · <span data-readout="fps">—</span></span>
        <span class="corner br">CH${channel}</span>
        <span class="corner bl">${shortName(d.name)}</span>`;
      wall.appendChild(panel);
    });
  }

  // ---- list view -----------------------------------------------------
  function renderList(host, devices, ctx) {
    const cols = [
      { key: null,      label: '' },
      { key: 'name',    label: 'Device' },
      { key: 'runtime', label: 'Runtime' },
      { key: 'state',   label: 'Status' },
      { key: 'fps',     label: 'FPS' },
      { key: 'lat',     label: 'Lat' },
      { key: 'scale',   label: 'Scale' },
      { key: null,      label: 'Tags' },
      { key: null,      label: '' }
    ];
    host.innerHTML = `
      <div class="list">
        <div class="list-header">
          ${cols.map(c => c.key
            ? `<div class="sortable" data-key="${c.key}"${ctx.sort.key === c.key ? ` data-dir="${ctx.sort.dir}"` : ''}>${c.label}</div>`
            : `<div>${c.label}</div>`).join('')}
        </div>
        <div data-role="list-body"></div>
      </div>`;
    const body = host.querySelector('[data-role="list-body"]');
    devices.forEach((d, i) => {
      const row = document.createElement('div');
      row.className = 'list-row' + (ctx.selectedUdid === d.udid ? ' selected' : '');
      row.dataset.udid = d.udid;
      row.dataset.state = d.uiState;
      row.style.animationDelay = (i * 12) + 'ms';
      row.innerHTML = `
        <span class="pip"></span>
        <div>
          <div class="nm">${escapeHTML(d.name)}</div>
          <div class="uu">${d.udid}</div>
        </div>
        <span class="rt">${escapeHTML(d.runtime)}</span>
        <span class="st">${stateLabel(d.uiState)}</span>
        <span class="num ${d.uiState === 'live' ? 'lime' : 'dim'}" data-readout="fps">—</span>
        <span class="num ${d.uiState === 'live' ? 'amber' : 'dim'}" data-readout="lat">—</span>
        <span class="num" data-readout="scale">—</span>
        <div class="tag-row">
          <span class="t">${escapeHTML(d.platform)}</span>
        </div>
        <div class="row-actions">
          <button class="qa" data-action="snapshot" title="Snapshot">◉</button>
          <button class="qa" data-action="reset" title="Force IDR">↻</button>
          <button class="qa" data-action="open" title="Open">↗</button>
        </div>`;
      body.appendChild(row);
    });
  }

  // ---- empty focus ---------------------------------------------------
  function renderFocusEmpty(host) {
    host.innerHTML = `
      <div class="focus-empty">
        <pre class="ascii">┌──────────┐
│  ╳   ╳   │
│          │
│  ── ──── │
└──────────┘</pre>
        <div class="big">No device focused.</div>
        <div class="sm">Pick any tile in the grid to mirror its stream,<br>read live telemetry, and send gestures.</div>
      </div>`;
  }

  // ---- CLI mirror ----------------------------------------------------
  function renderCli(host, ctx) {
    const platforms = [...ctx.filter.platforms].join(',') || '∅';
    const runtimes  = [...ctx.filter.runtimes].join(',') || '∅';
    const focus = ctx.selectedUdid
      ? ` <span class="flag">--focus</span> <span class="arg">${ctx.selectedUdid}</span>`
      : '';
    host.innerHTML = `
      <div class="lab">CLI&nbsp;Mirror</div>
      <div class="cmd">
        <span class="prompt">$</span> baguette
        <span class="arg">serve</span>
        <span class="flag">--platform</span> ${platforms}
        <span class="flag">--runtime</span> ${runtimes}
        <span class="flag">--port</span> ${location.port || '8421'}${focus}
      </div>
      <button class="copy">Copy</button>`;
  }

  // ---- helpers -------------------------------------------------------
  function shapeFor(p) {
    return p === 'ipad' ? 'ipad'
         : p === 'tv'    ? 'tv'
         : p === 'watch' ? 'watch'
         : '';
  }
  function stateLabel(s) {
    return ({ live: 'LIVE', boot: 'BOOTING', idle: 'BOOTED', off: 'SHUTDOWN', error: 'ERROR' })[s] || s.toUpperCase();
  }
  function shortName(n) {
    return n.replace(/iPhone\s+/, '').replace(/Apple\s+/, '').replace(/\s*\(.*?\)/, '').toUpperCase();
  }
  function overlayFor(d, dimOnly) {
    if (d.uiState === 'live')   return '';
    if (d.uiState === 'boot')   return `<div class="off-overlay" style="color:var(--amber)">··· BOOTING ···</div>`;
    if (d.uiState === 'error')  return `<div class="err-overlay">FAULT&nbsp;·&nbsp;HID&nbsp;UNAVAIL</div>`;
    if (d.uiState === 'idle')   return dimOnly ? '' : `<div class="off-overlay" style="color:var(--muted);background:rgba(0,0,0,0.5)">IDLE · NOT STREAMING</div>`;
    return `<div class="off-overlay">SHUTDOWN</div>`;
  }
  function escapeHTML(s) {
    return String(s ?? '').replace(/[&<>"']/g, c =>
      ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  window.FarmViews = {
    renderHeader, renderRail, renderGridHead,
    renderGrid, renderWall, renderList,
    renderFocusEmpty, renderCli,
    stateLabel, shapeFor, escapeHTML
  };
})();
