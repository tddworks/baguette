// sim-ax-inspector.js — accessibility-tree overlay for the live
// stream view. Hangs `window.AXInspector` on the global; sim-stream.js
// wires one instance per active stream.
//
// Behaviour:
//   - The overlay activates when the caller calls `enable()` (sidebar
//     mode renders an inline toggle in `host`; focus mode drives this
//     from a toolbar button).
//   - When enabled, the AX tree is fetched once and re-fetched on
//     every fresh hover (mouseenter on the screen) and on click,
//     so the user sees a fresh snapshot per inspection without
//     paying for a polling loop.
//   - Hover hit-tests the cached tree client-side (Domain `AXNode`
//     ships frames in the same device-point space as gestures), and
//     paints a translucent box + tooltip over the hovered node.
//   - Clicking locks the selection. The inspector renders the
//     selection into `host` (if provided) and fires `onSelect(node)`
//     so callers without an inline host (focus mode) can show it
//     elsewhere — e.g. a slide-up sheet.
//
// While enabled, the overlay swallows mouse events so taps don't
// bleed into the gesture pipeline. While disabled, the overlay is
// `pointer-events:none` and the underlying gesture surface behaves
// exactly as before.
//
// Wire dependency:
//   - Sends   `{"type":"describe_ui"}`    over the stream WS.
//   - Receives `{"type":"describe_ui_result","ok":true,"tree":…}`
//     from same WS (or `{"ok":false,"error":…}` on failure).
// AX tree shape mirrors `Domain/Accessibility/AXNode.swift`.

(function () {
  'use strict';

  // --- Pure helpers -------------------------------------------------

  // Deepest descendant whose frame contains (x, y). Mirrors
  // `AXNode.hitTest` in Domain so the JS overlay and the Swift
  // CLI/programmatic API pick the same element. `hidden === true`
  // nodes are skipped entirely — they're not interactable from the
  // user's perspective.
  function hitTest(node, x, y) {
    if (!node || node.hidden === true) return null;
    if (!nodeContains(node, x, y)) return null;
    const kids = node.children || [];
    for (let i = kids.length - 1; i >= 0; i--) {
      const m = hitTest(kids[i], x, y);
      if (m) return m;
    }
    return node;
  }

  function nodeContains(n, x, y) {
    const f = n && n.frame;
    if (!f) return false;
    return x >= f.x && y >= f.y && x < f.x + f.width && y < f.y + f.height;
  }

  function escapeHTML(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
    })[c]);
  }

  // Render the selection details + action row into an arbitrary host
  // element. Exposed as a static so both the sidebar mode (in-card)
  // and the focus mode (in-sheet) can reuse the same markup.
  //
  // `ctx`: { send, getDeviceSize }
  //   - send:          (payload) => void  — dispatch a JSON envelope on the WS
  //   - getDeviceSize: () => { w, h }     — device-point dims for `tap`
  //
  // The button row is laid out as:
  //   [ Copy id ] [ Copy JSON ]
  //   [        Tap (cx, cy)        ]
  // The 2-up + full-width pattern keeps every button readable in a
  // narrow ~220px sidebar without text wrapping; Tap is the primary
  // action so it gets the prominent full-width slot.
  function renderSelectionInto(host, node, ctx) {
    if (!host) return;
    if (!node) {
      host.style.display = 'none';
      host.innerHTML = '';
      return;
    }
    const cx = node.frame.x + node.frame.width  / 2;
    const cy = node.frame.y + node.frame.height / 2;
    const row = (k, v) => v == null || v === '' ? ''
      : '<div><span style="color:var(--text-muted);display:inline-block;width:60px">' +
        k + '</span>' + escapeHTML(v) + '</div>';

    host.style.display = '';
    host.innerHTML =
      '<div style="font-size:11px;line-height:1.45;' +
        'font-family:ui-monospace,SFMono-Regular,Menlo,monospace">' +
        row('role',  node.role) +
        row('label', node.label) +
        row('id',    node.identifier) +
        row('value', node.value) +
        '<div><span style="color:var(--text-muted);display:inline-block;width:60px">frame</span>' +
          node.frame.x.toFixed(0) + ',' + node.frame.y.toFixed(0) + ' ' +
          node.frame.width.toFixed(0) + '×' + node.frame.height.toFixed(0) +
        '</div>' +
      '</div>' +
      '<div style="display:grid;grid-template-columns:1fr 1fr;gap:6px;margin-top:8px">' +
        '<button class="btn btn-sm" data-act="copy-id"' +
          (node.identifier ? '' : ' disabled') +
          ' style="white-space:nowrap">Copy id</button>' +
        '<button class="btn btn-sm" data-act="copy-json"' +
          ' style="white-space:nowrap">Copy JSON</button>' +
      '</div>' +
      '<button class="btn btn-sm btn-primary" data-act="tap"' +
        ' style="width:100%;margin-top:6px;white-space:nowrap">' +
        'Tap (' + cx.toFixed(0) + ', ' + cy.toFixed(0) + ')' +
      '</button>';

    const copyId = host.querySelector('[data-act="copy-id"]');
    if (copyId && node.identifier) {
      copyId.addEventListener('click', () => {
        navigator.clipboard?.writeText(node.identifier);
      });
    }
    host.querySelector('[data-act="copy-json"]')
      .addEventListener('click', () => {
        navigator.clipboard?.writeText(JSON.stringify(node, null, 2));
      });
    host.querySelector('[data-act="tap"]')
      .addEventListener('click', () => {
        // Wire shape matches GestureRegistry's `tap`: device-point
        // coordinates plus the device-point screen size.
        const sz = (ctx.getDeviceSize && ctx.getDeviceSize()) || { w: 0, h: 0 };
        ctx.send({
          type: 'tap',
          x: cx, y: cy, width: sz.w, height: sz.h,
        });
      });
  }

  // --- AXInspector --------------------------------------------------

  class AXInspector {
    constructor(opts) {
      this.host           = opts.host || null;       // optional sidebar mount
      this.screenArea     = opts.screenArea;         // overlay parent (already position:absolute)
      this.send           = opts.send;               // (payload) => void  — JSON over stream WS
      this.getDeviceSize  = opts.getDeviceSize;      // () => { w, h }     — device-point dims
      this.onSelect       = opts.onSelect       || null; // (node | null) => void
      this.onStatus       = opts.onStatus       || null; // (text)         => void
      this.onEnableChange = opts.onEnableChange || null; // (enabled: bool) => void

      this.tree = null;
      this.hover = null;
      this.selected = null;
      this.enabled = false;

      if (this.host) this._buildSidebar();
      this._buildOverlay();
    }

    /// Public: dispatch a stream-WS text envelope. Returns `true`
    /// when the envelope was consumed (so StreamSession's onText
    /// hook can short-circuit the decoder).
    handleEnvelope(env) {
      if (!env || env.type !== 'describe_ui_result') return false;
      if (env.ok && env.tree) {
        this.tree = env.tree;
        this._setStatus('');
      } else {
        this.tree = null;
        this._setStatus(env.error || 'no accessibility data');
      }
      this._draw();
      return true;
    }

    enable() {
      if (this.enabled) return;
      this.enabled = true;
      if (this.toggleEl) this.toggleEl.checked = true;
      this.overlay.style.display = '';
      this.overlay.style.pointerEvents = 'auto';
      this._refresh();
      if (this.onEnableChange) this.onEnableChange(true);
    }

    disable() {
      if (!this.enabled) return;
      this.enabled = false;
      if (this.toggleEl) this.toggleEl.checked = false;
      this.overlay.style.pointerEvents = 'none';
      this.overlay.style.display = 'none';
      this.tree = null;
      this.hover = null;
      this.selected = null;
      this._setStatus('');
      this._renderInfo();
      this._draw();
      if (this.onSelect) this.onSelect(null);
      if (this.onEnableChange) this.onEnableChange(false);
    }

    isEnabled() { return this.enabled; }

    detach() {
      try { this.disable(); } catch { /* ignore */ }
      if (this._onResize) {
        window.removeEventListener('resize', this._onResize);
        this._onResize = null;
      }
      if (this.overlay && this.overlay.parentNode) {
        this.overlay.parentNode.removeChild(this.overlay);
      }
      if (this.host) this.host.innerHTML = '';
    }

    // --- internal: sidebar UI -----------------------------------

    _buildSidebar() {
      this.host.innerHTML =
        '<label style="display:flex;align-items:center;gap:8px;font-size:11px;cursor:pointer;user-select:none">' +
          '<input type="checkbox" data-role="toggle">' +
          '<span>Inspect (hover)</span>' +
          '<span data-role="status" style="margin-left:auto;color:var(--text-muted);font-size:10px"></span>' +
        '</label>' +
        '<div data-role="info" style="margin-top:8px;display:none"></div>';
      this.toggleEl = this.host.querySelector('[data-role="toggle"]');
      this.statusEl = this.host.querySelector('[data-role="status"]');
      this.infoEl   = this.host.querySelector('[data-role="info"]');
      this.toggleEl.addEventListener('change', () => {
        if (this.toggleEl.checked) this.enable(); else this.disable();
      });
    }

    _setStatus(text) {
      const t = text || '';
      if (this.statusEl) this.statusEl.textContent = t;
      if (this.onStatus) this.onStatus(t);
    }

    // --- internal: overlay canvas + mouse handlers --------------

    _buildOverlay() {
      const ov = document.createElement('canvas');
      ov.style.cssText =
        'position:absolute;inset:0;pointer-events:none;display:none;z-index:5';
      this.overlay = ov;
      this.screenArea.appendChild(ov);
      this._sizeOverlay();

      this._onResize = () => { this._sizeOverlay(); this._draw(); };
      window.addEventListener('resize', this._onResize);

      // Bind once — handlers no-op when disabled (events don't fire
      // anyway because pointer-events:none in that state, but we
      // guard defensively).
      ov.addEventListener('mouseenter', () => {
        if (this.enabled) this._refresh();
      });
      ov.addEventListener('mousemove', (e) => {
        if (this.enabled) this._handleMove(e);
      });
      ov.addEventListener('mouseleave', () => {
        if (!this.enabled) return;
        this.hover = null;
        this._draw();
      });
      ov.addEventListener('mousedown', (e) => {
        if (!this.enabled) return;
        e.preventDefault();
        e.stopPropagation();
      });
      ov.addEventListener('click', (e) => {
        if (!this.enabled) return;
        e.preventDefault();
        e.stopPropagation();
        this._handleClick(e);
      });
    }

    _sizeOverlay() {
      const r = this.screenArea.getBoundingClientRect();
      const dpr = window.devicePixelRatio || 1;
      this.overlay.width  = Math.max(1, Math.round(r.width  * dpr));
      this.overlay.height = Math.max(1, Math.round(r.height * dpr));
      this.overlay.style.width  = r.width + 'px';
      this.overlay.style.height = r.height + 'px';
    }

    // --- internal: events ---------------------------------------

    _refresh() {
      if (!this.enabled) return;
      this._setStatus('fetching…');
      try { this.send({ type: 'describe_ui' }); }
      catch { this._setStatus('send failed'); }
    }

    _handleMove(e) {
      if (!this.tree) return;
      const dev = this._toDevicePoint(e);
      const hit = hitTest(this.tree, dev.x, dev.y);
      if (hit !== this.hover) {
        this.hover = hit;
        this._draw();
      }
    }

    _handleClick() {
      this.selected = this.hover;
      this._renderInfo();
      this._draw();
      this._refresh();
      if (this.onSelect) this.onSelect(this.selected);
    }

    _renderInfo() {
      if (this.infoEl) {
        renderSelectionInto(this.infoEl, this.selected, {
          send: this.send,
          getDeviceSize: this.getDeviceSize,
        });
      }
    }

    _toDevicePoint(e) {
      const r = this.screenArea.getBoundingClientRect();
      const fx = (e.clientX - r.left) / Math.max(1, r.width);
      const fy = (e.clientY - r.top)  / Math.max(1, r.height);
      const sz = this.getDeviceSize() || { w: 0, h: 0 };
      return { x: fx * sz.w, y: fy * sz.h };
    }

    // --- internal: rendering ------------------------------------

    _draw() {
      this._sizeOverlay();
      const ctx = this.overlay.getContext('2d');
      ctx.clearRect(0, 0, this.overlay.width, this.overlay.height);
      if (!this.enabled) return;

      const sz = this.getDeviceSize() || { w: 0, h: 0 };
      if (!sz.w || !sz.h) return;
      const sx = this.overlay.width  / sz.w;
      const sy = this.overlay.height / sz.h;

      const drawNode = (n, stroke, fill, lw) => {
        if (!n || !n.frame) return;
        const x = n.frame.x * sx, y = n.frame.y * sy;
        const w = n.frame.width  * sx;
        const h = n.frame.height * sy;
        ctx.lineWidth = lw;
        ctx.strokeStyle = stroke;
        ctx.fillStyle   = fill;
        ctx.fillRect(x, y, w, h);
        ctx.strokeRect(x, y, w, h);
      };

      drawNode(this.hover,    'rgba(37, 99, 235, 0.95)', 'rgba(37, 99, 235, 0.12)', 2);
      drawNode(this.selected, 'rgba(220, 38, 38, 0.95)', 'rgba(220, 38, 38, 0.10)', 2);

      if (this.hover) this._drawTooltip(ctx, this.hover, sx, sy);
    }

    _drawTooltip(ctx, n, sx, sy) {
      const label = n.label || n.identifier || n.title || n.role || '';
      if (!label) return;
      const text = (n.role ? '[' + n.role + '] ' : '') + label;
      const dpr = window.devicePixelRatio || 1;
      ctx.font = (11 * dpr) + 'px ui-monospace,SFMono-Regular,Menlo,monospace';
      const metrics = ctx.measureText(text);
      const padX = 6 * dpr, padY = 4 * dpr;
      const w = Math.min(this.overlay.width - 8 * dpr, metrics.width + padX * 2);
      const h = 16 * dpr + padY * 2 - 8 * dpr;
      let x = n.frame.x * sx;
      let y = n.frame.y * sy - h - 4 * dpr;
      if (y < 4 * dpr) y = (n.frame.y + n.frame.height) * sy + 4 * dpr;
      if (x + w > this.overlay.width) x = this.overlay.width - w - 4 * dpr;
      if (x < 4 * dpr) x = 4 * dpr;
      ctx.fillStyle = 'rgba(15,23,42,0.92)';
      ctx.fillRect(x, y, w, h);
      ctx.fillStyle = '#fff';
      ctx.textBaseline = 'middle';
      ctx.fillText(text, x + padX, y + h / 2);
    }
  }

  AXInspector.renderSelectionInto = renderSelectionInto;
  window.AXInspector = AXInspector;
})();
