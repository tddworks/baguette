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

  function buildShell(host, opts) {
    // Two stacked children inside the caller's container:
    //   1. A compact controls strip (filter input + level select + clear).
    //   2. A scrolling monospace list.
    // The controls strip carries no padding overrides — it inherits
    // the surrounding card's tokens, so it matches the rest of the
    // sidebar / sheet visually.
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

      this.els = buildShell(host, opts);
      this.els.level.value = this.level;

      this._renderScheduled = false;
      this._renderTick = () => {
        this._renderScheduled = false;
        this._render();
      };

      this.els.filter.addEventListener('input', () => {
        this.filter = this.els.filter.value.trim().toLowerCase();
        this._scheduleRender();
      });
      this.els.level.addEventListener('change', () => {
        this.level = this.els.level.value;
        this._reconnect();
      });
      this.els.clear.addEventListener('click', () => {
        this.lines = [];
        this._scheduleRender();
      });

      this._connect();
    }

    detach() {
      if (this.ws) {
        try { this.ws.close(); } catch (_) { /* ignore */ }
        this.ws = null;
      }
      if (this.host) this.host.innerHTML = '';
    }

    // Coalesce N message-driven renders per frame into one. Without
    // this, a flood of `log` envelopes (CoreDuet-style chatter at
    // hundreds of lines/sec) triggers a full innerHTML rebuild +
    // regex pass over up to MAX_LINES rows on every WS frame, which
    // pegs the main thread and stalls the rest of the page (stream
    // canvas, gestures).
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
        this.lines.push(env.line || '');
        if (this.lines.length > MAX_LINES) {
          this.lines.splice(0, this.lines.length - MAX_LINES);
        }
        this._scheduleRender();
      }
    }

    // --- rendering ---

    _renderPlaceholder(text) {
      this.els.list.innerHTML =
        '<div style="color:var(--text-muted)">' + escapeHTML(text) + '</div>';
    }

    _matchesFilter(line) {
      return !this.filter || line.toLowerCase().indexOf(this.filter) !== -1;
    }

    _render() {
      const visible = this.filter
        ? this.lines.filter((l) => this._matchesFilter(l))
        : this.lines;
      if (visible.length === 0) {
        this._renderPlaceholder(this.filter ? 'no matches' : 'waiting for log entries…');
        return;
      }
      // Single innerHTML write per render — much cheaper than
      // per-line appendChild when the buffer churns at hundreds of
      // lines/second.
      this.els.list.innerHTML = visible.map((l) =>
        '<div style="padding:2px 0;border-bottom:1px solid var(--border-light,rgba(0,0,0,0.05));white-space:pre-wrap;word-break:break-word">' +
          colourizeLine(l) +
        '</div>'
      ).join('');
      this.els.list.scrollTop = this.els.list.scrollHeight;
    }
  }

  window.LogPanel = LogPanel;
})();
