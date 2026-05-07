// sim-logs.js — live unified-log subscriber for the simulator pages.
//
// Hangs `window.LogPanel` on the global so the focus-mode page
// (sim-native.js) and the sidebar-mode page (sim-stream.js) can
// share one wiring pattern. Visual layout mirrors the sidebar's
// "Events" card: monospace, muted timestamps, severity-coloured
// type badge + message body, scrolling auto-pinned to the bottom.
//
// Controls strip above the scrolling list:
//   - Live-grep filter input (case-insensitive substring).
//   - Level select (info | debug | default).
//   - Clear button.
//
// Severity → colour:
//   F (Fault), E (Error)            → var(--danger)
//   I (Info)                        → var(--success)
//   Db (Debug), A (Activity)        → var(--text-muted)
//   Df (Default), Lt, T, …          → inherit
//
// Changing the level reopens the WS — the filter doesn't, since
// the server has no use for it (it's a client-side display
// concern). One LogPanel per host element. `detach()` closes the
// WS and clears the host.
//
// Performance shape:
//   - Server batches lines into one `{"type":"log","lines":[…]}`
//     envelope per ~50 ms (see Server.logsWS / LogBatcher), so the
//     WS-message rate is bounded regardless of log volume.
//   - Renders are append-only: each batch grows the DOM by N rows
//     via a DocumentFragment, never re-paints rows that are already
//     mounted. Filter/clear/level changes do a one-shot full rebuild.
//   - Trim: when the row count exceeds MAX_LINES we drop from the
//     front of the list (DOM + memory) to bound both.
//   - Hidden hosts skip rendering entirely; on reveal we do one
//     full rebuild to catch up.

(function () {
  'use strict';

  const MAX_LINES = 1500;

  function escapeHTML(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;');
  }

  // Parse a `log stream --style compact` line into severity-coloured
  // spans. Format:
  //   <YYYY-MM-DD> <HH:MM:SS.mmm> <Type> <process>[<pid>:<tid>] <rest>
  // Returns the line as plain HTML when the regex misses (rare —
  // only happens for `log`'s own startup banners like
  // "getpwuid_r did not find a match for uid 501").
  function colourizeLine(line) {
    const m = line.match(/^(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2}\.\d+)\s+([A-Z][a-z]?)\s+(\S+)\s*(.*)$/);
    if (!m) return '<span style="color:var(--text-muted)">' + escapeHTML(line) + '</span>';
    const time = m[2], type = m[3], proc = m[4], rest = m[5];
    let bodyColor = 'inherit';
    if (type === 'E' || type === 'F') bodyColor = 'var(--danger)';
    else if (type === 'I')            bodyColor = 'var(--success)';
    else if (type === 'Db' || type === 'A') bodyColor = 'var(--text-muted)';
    return (
      '<span style="color:var(--text-muted);margin-right:6px">' +
        escapeHTML(time) +
      '</span>' +
      '<span style="color:' + bodyColor + ';font-weight:600;margin-right:6px">' +
        escapeHTML(type) +
      '</span>' +
      '<span style="color:var(--text-muted);margin-right:6px">' +
        escapeHTML(proc) +
      '</span>' +
      '<span style="color:' + bodyColor + '">' +
        escapeHTML(rest) +
      '</span>'
    );
  }

  const ROW_STYLE =
    'padding:2px 0;border-bottom:1px solid var(--border-light,rgba(0,0,0,0.05));' +
    'white-space:pre-wrap;word-break:break-word';

  function makeRow(line) {
    const div = document.createElement('div');
    div.setAttribute('style', ROW_STYLE);
    div.innerHTML = colourizeLine(line);
    return div;
  }

  function buildShell(host, opts) {
    const inputStyle =
      'padding:2px 6px;font-size:11px;font-family:inherit;' +
      'background:transparent;border:1px solid var(--border,#e5e7eb);' +
      'border-radius:4px;color:inherit;outline:none';
    const btnStyle =
      'padding:2px 8px;font-size:11px;font-family:inherit;' +
      'background:transparent;border:1px solid var(--border,#e5e7eb);' +
      'border-radius:4px;cursor:pointer;color:inherit';
    const listStyle =
      'padding:8px;overflow-y:auto;font-size:11px;' +
      'font-family:ui-monospace,SFMono-Regular,Menlo,monospace;' +
      (opts.listMaxHeight ? 'max-height:' + opts.listMaxHeight + ';' : 'max-height:200px;');

    host.innerHTML =
      '<div data-role="controls" style="display:flex;gap:6px;align-items:center;padding:6px 8px;' +
        'border-bottom:1px solid var(--border-light,rgba(0,0,0,0.05));font-size:11px;' +
        'font-family:ui-monospace,SFMono-Regular,Menlo,monospace">' +
        '<input data-role="filter" placeholder="filter…" style="flex:1;min-width:0;' + inputStyle + '">' +
        '<select data-role="level" style="' + inputStyle + '">' +
          '<option value="info">info</option>' +
          '<option value="debug">debug</option>' +
          '<option value="default">default</option>' +
        '</select>' +
        '<button data-role="clear" type="button" style="' + btnStyle + '">Clear</button>' +
      '</div>' +
      '<div data-role="list" style="' + listStyle + '">' +
        '<div style="color:var(--text-muted)">Connecting…</div>' +
      '</div>';

    return {
      filter: host.querySelector('[data-role="filter"]'),
      level:  host.querySelector('[data-role="level"]'),
      clear:  host.querySelector('[data-role="clear"]'),
      list:   host.querySelector('[data-role="list"]'),
    };
  }

  function wsURL(udid, level, style, bundleId) {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const params = new URLSearchParams();
    params.set('level', level);
    params.set('style', style);
    if (bundleId) params.set('bundleId', bundleId);
    return proto + '//' + location.host
      + '/simulators/' + encodeURIComponent(udid) + '/logs?'
      + params.toString();
  }

  // Treat the list as auto-scrolling when the user is within this
  // many pixels of the bottom; otherwise leave their scroll position
  // alone so they can read history while new lines arrive.
  const STICK_THRESHOLD_PX = 24;

  class LogPanel {
    constructor(host, opts) {
      opts = opts || {};
      this.host = host;
      this.udid = opts.udid;
      this.level = opts.level || 'info';
      this.style = opts.style || 'compact';
      this.bundleId = opts.bundleId || '';
      this.lines = [];
      this.filter = '';
      this.ws = null;

      // Pending lines (received from WS but not yet on screen).
      // Drained on every render tick.
      this._pending = [];
      // Set when filter/clear/level changes invalidate the existing
      // DOM rows — next render does a full rebuild instead of append.
      this._dirty = true;

      this.els = buildShell(host, opts);
      this.els.level.value = this.level;

      this._renderScheduled = false;
      this._renderTick = () => {
        this._renderScheduled = false;
        this._render();
      };

      this.els.filter.addEventListener('input', () => {
        this.filter = this.els.filter.value.trim().toLowerCase();
        this._dirty = true;
        this._scheduleRender();
      });
      this.els.level.addEventListener('change', () => {
        this.level = this.els.level.value;
        this._reconnect();
      });
      this.els.clear.addEventListener('click', () => {
        this.lines = [];
        this._pending = [];
        this._dirty = true;
        this._scheduleRender();
      });

      // Pause rendering when the host isn't visible (e.g. collapsed
      // sidebar, off-screen sheet). Lines still accumulate in
      // `this.lines` up to MAX_LINES; on reveal we do one full
      // rebuild to catch the user up.
      this._visible = true;
      if (typeof IntersectionObserver === 'function') {
        this._io = new IntersectionObserver((entries) => {
          for (const e of entries) {
            const wasVisible = this._visible;
            this._visible = e.isIntersecting;
            if (this._visible && !wasVisible) {
              this._dirty = true;
              this._scheduleRender();
            }
          }
        });
        this._io.observe(host);
      }

      this._connect();
    }

    detach() {
      if (this._io) { try { this._io.disconnect(); } catch (_) { /* ignore */ } this._io = null; }
      if (this.ws) {
        try { this.ws.close(); } catch (_) { /* ignore */ }
        this.ws = null;
      }
      if (this.host) this.host.innerHTML = '';
    }

    // Coalesce many incoming batches into one render per frame.
    _scheduleRender() {
      if (this._renderScheduled) return;
      this._renderScheduled = true;
      requestAnimationFrame(this._renderTick);
    }

    // --- ws lifecycle ---

    _connect() {
      if (!this.udid) {
        this._renderPlaceholder('No simulator selected');
        return;
      }
      const url = wsURL(this.udid, this.level, this.style, this.bundleId);
      try {
        this.ws = new WebSocket(url);
      } catch (e) {
        this._renderPlaceholder('error: ' + e.message);
        return;
      }
      this.ws.addEventListener('message', (ev) => this._onMessage(ev.data));
      this.ws.addEventListener('close', () => {
        if (this.lines.length === 0) this._renderPlaceholder('disconnected');
      });
      this.ws.addEventListener('error', () => {
        if (this.lines.length === 0) this._renderPlaceholder('error');
      });
    }

    _reconnect() {
      if (this.ws) {
        try { this.ws.close(); } catch (_) { /* ignore */ }
        this.ws = null;
      }
      this.lines = [];
      this._pending = [];
      this._dirty = true;
      this._renderPlaceholder('Reconnecting at ' + this.level + '…');
      this._connect();
    }

    _onMessage(data) {
      let env;
      try { env = JSON.parse(String(data)); } catch (_) { return; }
      if (!env || !env.type) return;
      if (env.type === 'log_started') {
        if (this.lines.length === 0) this._renderPlaceholder('Waiting for log entries…');
        return;
      }
      if (env.type === 'log_stopped') {
        if (this.lines.length === 0) {
          this._renderPlaceholder('stopped' + (env.reason ? ': ' + env.reason : ''));
        }
        return;
      }
      if (env.type === 'log') {
        // Server sends batches as `lines: [...]`; tolerate the older
        // single-line shape too in case mismatched server/client.
        const incoming = Array.isArray(env.lines)
          ? env.lines
          : (typeof env.line === 'string' ? [env.line] : []);
        if (incoming.length === 0) return;
        for (const l of incoming) {
          this.lines.push(l);
          this._pending.push(l);
        }
        // Trim from the front if over the row cap. If we drop more
        // than we'd append this frame, the cheaper path is a full
        // rebuild — flag dirty.
        if (this.lines.length > MAX_LINES) {
          const drop = this.lines.length - MAX_LINES;
          this.lines.splice(0, drop);
          this._dirty = true;
        }
        this._scheduleRender();
      }
    }

    // --- rendering ---

    _renderPlaceholder(text) {
      this.els.list.innerHTML =
        '<div style="color:var(--text-muted)">' + escapeHTML(text) + '</div>';
      this._dirty = true;        // any subsequent log render must rebuild
      this._pending = [];
    }

    _matchesFilter(line) {
      return !this.filter || line.toLowerCase().indexOf(this.filter) !== -1;
    }

    _render() {
      if (!this._visible) {
        // Drop the pending queue — when we become visible again the
        // next render does a full rebuild from `this.lines`.
        this._pending = [];
        this._dirty = true;
        return;
      }

      const list = this.els.list;
      const stick =
        list.scrollTop + list.clientHeight >= list.scrollHeight - STICK_THRESHOLD_PX;

      if (this._dirty) {
        // Full rebuild path: filter changed, clear, reveal, or
        // big trim. Build once into a fragment, swap in.
        const frag = document.createDocumentFragment();
        let count = 0;
        for (const l of this.lines) {
          if (this._matchesFilter(l)) {
            frag.appendChild(makeRow(l));
            count++;
          }
        }
        list.innerHTML = '';
        if (count === 0) {
          list.innerHTML =
            '<div style="color:var(--text-muted)">' +
            escapeHTML(this.filter ? 'no matches' : 'waiting for log entries…') +
            '</div>';
        } else {
          list.appendChild(frag);
        }
        this._dirty = false;
        this._pending = [];
      } else if (this._pending.length > 0) {
        // Append-only path: only the new lines from this frame go
        // through colourizeLine, regardless of buffer depth.
        const frag = document.createDocumentFragment();
        let appended = 0;
        for (const l of this._pending) {
          if (this._matchesFilter(l)) {
            frag.appendChild(makeRow(l));
            appended++;
          }
        }
        this._pending = [];
        if (appended > 0) {
          // If the placeholder ("waiting for log entries…") is
          // currently the only child, drop it before appending real
          // rows.
          if (list.children.length === 1 &&
              list.children[0].getAttribute('style') !== ROW_STYLE) {
            list.innerHTML = '';
          }
          list.appendChild(frag);
          // Trim the rendered DOM to MAX_LINES too, so a long-running
          // session doesn't grow the layer tree without bound.
          while (list.children.length > MAX_LINES) {
            list.removeChild(list.firstChild);
          }
        }
      }

      if (stick) list.scrollTop = list.scrollHeight;
    }
  }

  window.LogPanel = LogPanel;
})();
