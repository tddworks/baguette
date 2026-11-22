// sim-defaults.js — the Defaults card for the focus page.
//
// Exports `DefaultsPanel` (also on `window`, for the classic pages) so page/device-page.js can surface a
// floating glass card that reads and edits an installed app's persisted
// UserDefaults: its standard suite, one of its App Groups, or a suite of its
// own.
//
// The card is a dumb sender. It lists apps (`apps.json`) and their groups
// (`defaults/groups.json`), draws the typed values `defaults.json` reads back
// — and, under them, the settings the running app reads that nothing stores
// (`lookups`) — and posts each edit with the type it was read as; Swift
// validates and stores. Row shaping and request bodies live in
// `defaults/preference-rows.js`, where they are unit-tested.
// See `docs/features/defaults/README.md`.
import { PreferenceRows } from './preference-rows.js';


const OTHER = '__other__';

function esc(text) {
  return String(text)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

const ICON_X = '<svg viewBox="0 0 24 24" width="11" height="11" fill="none" stroke="currentColor" '
  + 'stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg>';
const ICON_RELOAD = '<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" '
  + 'stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M20 12a8 8 0 1 1-2.3-5.6"/>'
  + '<path d="M20 4v5h-5"/></svg>';
const ICON_CHECK = '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" '
  + 'stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
  + '<path d="M5 12.5l4.5 4.5L19 7.5"/></svg>';
const ICON_CHEVRON = '<svg viewBox="0 0 24 24" width="9" height="9" fill="none" stroke="currentColor" '
  + 'stroke-width="2.6" stroke-linecap="round" aria-hidden="true"><path d="M6 9l6 6 6-6"/></svg>';

/** How often the open card re-reads. Each read is two simctl children
 *  (~0.4 s measured), so this keeps well clear of overlapping itself. */
const WATCH_MS = 2000;

const PLACEHOLDERS = {
  bool: 'true / false', int: '42', float: '1.5', string: 'text',
  date: '2026-01-02T03:04:05Z', data: 'base64', plist: '<array>…</array>',
};

class DefaultsPanel {
  constructor() {
    this.host = null;
    this.udid = null;
    this.apps = [];
    this.bundleId = null;
    this.suite = null;
    this.rows = [];
    this.unset = [];           // settings the running app reads, nothing stores
    this.answered = false;     // whether a running app said which it reads
    this.open = null;          // key of the expanded plist row
    this.rowErrors = {};       // key → message from a refused value
    this.drafts = {};          // key → the refused text, kept in its field
    this.relaunch = true;      // relaunch when the app wouldn't see a change (whenNeeded)
    this.filterText = '';
    this.flash = [];           // keys the app just changed, highlighted once
    this._replaceKey = null;   // data row whose bytes the file picker replaces
    this._poll = null;
  }

  /** @param {HTMLElement} host @param {string} udid */
  attach(host, udid) {
    if (!host || !udid) return;
    this.host = host;
    this.udid = udid;
    this._build();
    this._loadApps();
    this._poll = setInterval(() => this._watch(), WATCH_MS);
  }

  detach() {
    clearInterval(this._poll);
    if (this.host) { this.host.innerHTML = ''; this.host = null; }
  }

  /** Monitor: re-read while the card is open, so a value the app writes
   *  shows up (and flashes) without pressing Reload. Skipped while the
   *  card is shut (its sheet is inert), the tab is hidden, or a field in
   *  the card has focus — a re-render would throw away what's being
   *  typed. */
  _watch() {
    if (!this.host || !this.bundleId || document.hidden) return;
    if (this.host.closest('[inert]')) return;
    if (this.host.contains(document.activeElement) && document.activeElement.matches('input, textarea, select')) return;
    if (this.open) return;
    this._load({ quiet: true });
  }

  /** Re-read the device — the card opened again, things may have moved. */
  refresh() {
    if (this.bundleId) this._load();
  }

  get _R() { return PreferenceRows; }
  _$(selector) { return this.host.querySelector(selector); }
  _url(path) { return `/devices/${encodeURIComponent(this.udid)}${path}`; }

  _appName() {
    const app = this.apps.find((a) => a.bundleId === this.bundleId);
    return app ? app.name : this.bundleId;
  }

  // MARK: - skeleton

  _build() {
    this.host.innerHTML = `
      <div class="df-section">
        <div class="df-row"><label for="dfApp">App</label>
          <select id="dfApp" class="df-field"><option>Loading…</option></select></div>
        <div class="df-row"><label for="dfSuite">Suite</label>
          <select id="dfSuite" class="df-field"></select></div>
        <div class="df-row df-other" hidden><span aria-hidden="true"></span>
          <div class="df-other-body">
            <input id="dfOther" class="df-field df-mono" aria-label="Other suite name"
                   placeholder="com.example.suite" spellcheck="false">
            <span class="df-hint">A suite of the app's own, stored in its data container.</span>
          </div></div>
      </div>
      <div class="df-notice" role="alert" hidden></div>
      <div class="df-section">
        <input class="df-field df-mono df-filter" type="search" aria-label="Filter by key or type"
               placeholder="Filter by key or type" spellcheck="false">
        <div class="df-title"><span class="df-count"></span>
          <button class="df-icon" data-act="reload" aria-label="Reload" title="Reload">${ICON_RELOAD}</button></div>
        <div class="df-rows"></div>
      </div>
      <div class="df-section df-unset-section" hidden>
        <div class="df-title"><span class="df-unset-count"></span></div>
        <div class="df-unset-rows"></div>
      </div>
      <div class="df-section">
        <div class="df-title"><span>Add a key</span></div>
        <div class="df-add">
          <input class="df-field df-mono df-new-key" aria-label="New key" placeholder="key" spellcheck="false">
          <select class="df-field df-mono df-new-type" aria-label="Type">
            ${Object.keys(PLACEHOLDERS).map((t) => `<option value="${t}">${t}</option>`).join('')}
          </select>
        </div>
        <div class="df-add df-add-value">
          <input class="df-field df-mono df-new-value" aria-label="New value"
                 placeholder="${esc(PLACEHOLDERS.bool)}" spellcheck="false">
          <button class="df-primary" data-act="add">Add</button>
        </div>
      </div>
      <div class="df-section">
        <div class="df-relaunch">
          <button class="df-switch" data-act="relaunch" role="switch" aria-checked="true"
                  aria-labelledby="dfRelaunchLabel"><span></span></button>
          <div><div class="df-relaunch-title" id="dfRelaunchLabel">Relaunch app when it won't see a change</div>
            <div class="df-hint">A <span class="df-live-dot"></span> live setting (one the app watches, like
              @AppStorage) changes in the running app at once. Others were read once, so the app is
              relaunched to pick them up.</div></div>
        </div>
        <div class="df-status" role="status"></div>
        <div class="df-two">
          <button class="df-secondary" data-act="export">Export JSON</button>
          <button class="df-secondary" data-act="import">Import…</button>
        </div>
        <input type="file" class="df-import-file" accept="application/json,.json" hidden>
        <input type="file" class="df-data-file" hidden>
      </div>`;

    this.host.addEventListener('click', (e) => this._onClick(e));
    this.host.addEventListener('input', (e) => {
      if (!e.target.matches('.df-filter')) return;
      this.filterText = e.target.value;
      this._render();
    });
    this.host.addEventListener('change', (e) => this._onChange(e));
    this.host.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && e.target.matches('.df-new-key, .df-new-value')) this._add();
    });
  }

  // MARK: - requests

  /** fetch → `{ ok, status, json }`; never throws. */
  async _request(method, path, body) {
    try {
      const res = await fetch(this._url(path), {
        method,
        headers: body ? { 'Content-Type': 'application/json' } : undefined,
        body: body ? JSON.stringify(body) : undefined,
      });
      const json = await res.json().catch(() => null);
      return { ok: res.ok, status: res.status, json };
    } catch (err) {
      return { ok: false, status: 0, json: { error: 'baguette serve is not reachable' } };
    }
  }

  _showNotice(status, json) {
    const notice = this._R.notice(status, json && json.error);
    const box = this._$('.df-notice');
    box.className = `df-notice df-${notice.tone}`;
    box.innerHTML = esc(notice.text)
      + (notice.action === 'boot' ? '<br><button class="df-chip" data-act="boot">Boot</button>' : '');
    box.hidden = false;
  }

  _clearNotice() { this._$('.df-notice').hidden = true; }

  _status(text, { warn = false } = {}) {
    const box = this._$('.df-status');
    if (warn) {
      box.className = 'df-status df-warn';
      box.innerHTML = `${esc(text)}<br><button class="df-primary df-sm" data-act="relaunch-now">`
        + `Relaunch ${esc(this._appName())}</button>`;
    } else {
      box.className = 'df-status';
      box.innerHTML = ICON_CHECK + esc(text);
    }
  }

  /** What the edit body asks of the running app. */
  get _relaunchChoice() { return this.relaunch ? 'whenNeeded' : false; }

  _isLive(key) {
    return [...this.rows, ...this.unset].some((r) => r.key === key && r.live);
  }

  /** After a stored change: say what happened to the running app —
   *  relaunched, changed live, or (relaunch off, a read-once key) still
   *  on the old value. */
  _stored(what, key, relaunched) {
    if (relaunched) {
      this._status(`${what} · relaunched ${this._appName()}`);
      this._reloadOnceAnswered();
    } else if (key === null || this._isLive(key)) {
      this._status(`${what} · ${this._appName()} updated live`);
    } else {
      this._status(`${what}. ${this._appName()} read it once, so it may show the old value until it `
        + 'reopens that screen or restarts.', { warn: true });
    }
  }

  // MARK: - loading

  async _loadApps() {
    const res = await this._request('GET', '/apps.json');
    if (!res.ok) { this._showNotice(res.status, res.json); return; }
    this.apps = res.json.apps || [];
    const own = this.apps.filter((a) => !a.system);
    const system = this.apps.filter((a) => a.system);
    const option = (a) => `<option value="${esc(a.bundleId)}">${esc(a.name)} — ${esc(a.bundleId)}</option>`;
    this._$('#dfApp').innerHTML =
      (own.length ? `<optgroup label="Apps">${own.map(option).join('')}</optgroup>` : '')
      + (system.length ? `<optgroup label="System">${system.map(option).join('')}</optgroup>` : '');
    const keep = this.apps.find((a) => a.bundleId === this.bundleId);
    const first = keep || own[0] || system[0];
    if (!first) return;
    this._$('#dfApp').value = first.bundleId;
    this._selectApp(first.bundleId);
  }

  async _selectApp(bundleId) {
    this.bundleId = bundleId;
    this.suite = null;
    this.open = null;
    this._$('.df-other').hidden = true;
    const res = await this._request('GET', `/defaults-groups.json?${this._R.query({ bundleId })}`);
    const groups = res.ok ? (res.json.groups || []) : [];
    this._$('#dfSuite').innerHTML = '<option value="">Standard</option>'
      + (groups.length
        ? `<optgroup label="App Groups">${groups.map((g) => `<option value="${esc(g)}">${esc(g)}</option>`).join('')}</optgroup>`
        : '')
      + `<option value="${OTHER}">Other suite…</option>`;
    this._load();
  }

  /** A relaunched app reads its settings as its first screen builds, a
   *  moment after launch; read again once it has had that moment. */
  _reloadOnceAnswered() {
    clearTimeout(this._answerTimer);
    this._answerTimer = setTimeout(() => { if (this.host) this._load(); }, 1500);
  }

  async _load({ quiet = false } = {}) {
    const query = this._R.query({ bundleId: this.bundleId, suite: this.suite, plist: true });
    const res = await this._request('GET', `/defaults.json?${query}`);
    if (quiet && !res.ok) return;
    if (!res.ok) {
      this.rows = [];
      this._render();
      this._showNotice(res.status, res.json);
      return;
    }
    const rows = this._R.fromRead(res.json);
    const unset = this._R.unsetFromRead(res.json);
    const answered = this._R.answered(res.json);
    const same = JSON.stringify([rows, unset, answered]) === JSON.stringify([this.rows, this.unset, this.answered]);
    if (quiet && same) return;
    this.flash = quiet ? this._R.changedKeys(this.rows, rows) : [];
    if (!quiet) this._clearNotice();
    this.rows = rows;
    this.unset = unset;
    this.answered = answered;
    this._render();
  }

  // MARK: - rows

  _control(row) {
    switch (row.control) {
      case 'switch':
        return `<button class="df-switch" role="switch" data-act="toggle" aria-checked="${row.checked}"
                 aria-label="${esc(row.key)}"><span></span></button>`;
      case 'data':
        return `<span class="df-size df-mono">${esc(row.summary)}</span>
                <button class="df-chip" data-act="replace">Replace…</button>`;
      case 'plist': {
        const isOpen = this.open === row.key;
        return `<button class="df-chip" data-act="expand" aria-expanded="${isOpen}">${esc(row.summary)}
                 <span class="df-chevron${isOpen ? ' df-open' : ''}">${ICON_CHEVRON}</span></button>`;
      }
      default: {
        const numeric = row.type === 'int' || row.type === 'float';
        const bad = this.rowErrors[row.key];
        return `<input class="df-value df-mono${numeric ? ' df-num' : ''}${bad ? ' df-bad' : ''}"
                 data-act="edit" aria-label="${esc(row.key)}"
                 value="${esc(bad ? this.drafts[row.key] : row.text)}"
                 ${bad ? 'aria-invalid="true"' : ''} spellcheck="false">`;
      }
    }
  }

  _unsetControl(row) {
    const bad = this.rowErrors[row.key];
    const field = (type) => `<input class="df-value df-mono${type === 'int' || type === 'float' ? ' df-num' : ''}${bad ? ' df-bad' : ''}"
             data-act="edit-unset" aria-label="${esc(row.key)}"
             placeholder="${esc(row.placeholder || PLACEHOLDERS[type] || 'value')}"
             value="${esc(bad ? this.drafts[row.key] : '')}"
             ${bad ? 'aria-invalid="true"' : ''} spellcheck="false">`;
    switch (row.control) {
      case 'switch':
        return `<button class="df-switch" role="switch" data-act="toggle-unset" aria-checked="${row.checked}"
                 aria-label="${esc(row.key)}"><span></span></button>`;
      case 'text':
        return field(row.type);
      default:
        return `<select class="df-field df-mono df-pick-type" aria-label="${esc(row.key)} type">
                  ${Object.keys(PLACEHOLDERS).map((t) => `<option value="${t}"${t === (row.type || 'string') ? ' selected' : ''}>${t}</option>`).join('')}
                </select>${field(row.type || 'string')}`;
    }
  }

  /** The settings the running app reads that nothing stores — or, when no
   *  running app can say, the relaunch that lets it. */
  _renderUnset() {
    const section = this._$('.df-unset-section');
    const title = this._$('.df-unset-count');
    const list = this._$('.df-unset-rows');
    if (!this.answered) {
      section.hidden = false;
      title.textContent = 'Not set';
      list.innerHTML = `<div class="df-discover">
          <span class="df-hint">Settings still on the app's own default are known only to the running app.
            Relaunch it from here and it can say which it reads.</span>
          <button class="df-secondary df-sm" data-act="discover">Relaunch ${esc(this._appName())}</button>
        </div>`;
      return;
    }
    const n = this.unset.length;
    const shown = this._R.filter(this.unset, this.filterText);
    section.hidden = shown.length === 0;
    title.textContent = `Not set · ${n} ${n === 1 ? 'key' : 'keys'} the app reads`;
    list.innerHTML = shown.map((row) => `
      <div class="df-item df-unset" data-key="${esc(row.key)}">
        <div class="df-item-main${row.control === 'pick' ? ' df-item-pick' : ''}">
          <span class="df-key df-mono" title="${esc(row.key)}${row.live ? ' — live: the running app updates at once' : ''}">${
            row.live ? '<span class="df-live-dot"></span>' : ''}${esc(row.key)}</span>
          <span class="df-type df-mono">${esc(row.type || 'any')}</span>
          <div class="df-control">${this._unsetControl(row)}</div>
          <span class="df-source" title="${row.source === 'registered'
            ? 'The fallback the app registered' : "Set in the app's code; only the app knows it"}">${
            row.source === 'registered' ? 'reg' : 'app'}</span>
        </div>
        ${this.rowErrors[row.key] ? `<div class="df-row-error">${esc(this.rowErrors[row.key])}</div>` : ''}
      </div>`).join('');
  }

  _render() {
    this._renderUnset();
    const shown = this._R.filter(this.rows, this.filterText);
    const n = this.rows.length;
    this._$('.df-count').textContent = `Stored · ${n} ${n === 1 ? 'key' : 'keys'}`;
    if (!n) {
      this._$('.df-rows').innerHTML = `<div class="df-empty"><b>Nothing stored in this suite</b>
        <span class="df-hint">An app stores a setting only once it changes. The ones it reads but
        hasn't stored are under Not set.</span></div>`;
      return;
    }
    if (!shown.length) {
      this._$('.df-rows').innerHTML = `<div class="df-empty"><span class="df-hint">No stored key matches
        “${esc(this.filterText.trim())}”.</span></div>`;
      return;
    }
    this._$('.df-rows').innerHTML = shown.map((row) => `
      <div class="df-item${this.flash.includes(row.key) ? ' df-flash' : ''}" data-key="${esc(row.key)}">
        <div class="df-item-main">
          <span class="df-key df-mono" title="${esc(row.key)}${row.live ? ' — live: the running app updates at once' : ''}">${
            row.live ? '<span class="df-live-dot"></span>' : ''}${esc(row.key)}</span>
          <span class="df-type df-mono">${esc(row.type)}</span>
          <div class="df-control">${this._control(row)}</div>
          <button class="df-icon df-delete" data-act="delete" aria-label="Delete ${esc(row.key)}"
                  title="Delete">${ICON_X}</button>
        </div>
        ${this.rowErrors[row.key] ? `<div class="df-row-error">${esc(this.rowErrors[row.key])}</div>` : ''}
        ${row.control === 'plist' && this.open === row.key ? `
        <div class="df-fragment">
          <textarea class="df-mono" rows="5" aria-label="${esc(row.key)} as plist XML"
                    spellcheck="false">${esc(row.text)}</textarea>
          <div class="df-fragment-foot"><span class="df-hint">Edit as plist XML, then save.</span>
            <button class="df-primary df-sm" data-act="save">Save</button></div>
        </div>` : ''}
      </div>`).join('');
  }

  // MARK: - edits

  async _write(key, type, value) {
    const body = this._R.writeBody({
      bundleId: this.bundleId, suite: this.suite, key, type, value, relaunch: this._relaunchChoice,
    });
    const res = await this._request('POST', '/defaults', body);
    if (res.status === 400) {
      this.rowErrors[key] = (res.json && res.json.error) || 'Not a valid value';
      this.drafts[key] = String(value);
      this._render();
      return false;
    }
    if (!res.ok) { this._showNotice(res.status, res.json); return false; }
    delete this.rowErrors[key];
    delete this.drafts[key];
    this._clearNotice();
    this._stored(`Wrote ${key}`, key, !!(res.json && res.json.relaunched));
    await this._load();
    return true;
  }

  async _delete(key) {
    const query = this._R.query({ bundleId: this.bundleId, suite: this.suite, key, relaunch: this._relaunchChoice });
    const res = await this._request('DELETE', `/defaults?${query}`);
    if (!res.ok) { this._showNotice(res.status, res.json); return; }
    delete this.rowErrors[key];
    this._stored(`Removed ${key}`, key, !!(res.json && res.json.relaunched));
    this._load();
  }

  async _add() {
    const key = this._$('.df-new-key').value.trim();
    if (!key) { this._$('.df-new-key').focus(); return; }
    const type = this._$('.df-new-type').value;
    const value = this._$('.df-new-value').value;
    const body = this._R.writeBody({
      bundleId: this.bundleId, suite: this.suite, key, type,
      value: type === 'bool' ? value.trim() : value, relaunch: this._relaunchChoice,
    });
    const res = await this._request('POST', '/defaults', body);
    if (!res.ok) { this._showNotice(res.status, res.json); return; }
    this._clearNotice();
    this._$('.df-new-key').value = '';
    this._$('.df-new-value').value = '';
    this._stored(`Wrote ${key}`, key, !!(res.json && res.json.relaunched));
    this._load();
  }

  _export() {
    this._request('GET', `/defaults.json?${this._R.query({ bundleId: this.bundleId, suite: this.suite })}`)
      .then((res) => {
        if (!res.ok) { this._showNotice(res.status, res.json); return; }
        const blob = new Blob([JSON.stringify(res.json, null, 2)], { type: 'application/json' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = this._R.exportFileName({ bundleId: this.bundleId, suite: this.suite });
        a.click();
        setTimeout(() => URL.revokeObjectURL(a.href), 1000);
      });
  }

  async _import(file) {
    let parsed;
    try {
      parsed = JSON.parse(await file.text());
    } catch (err) {
      this._showNotice(400, { error: `${file.name} is not JSON` });
      return;
    }
    const body = this._R.importBody({
      bundleId: this.bundleId, suite: this.suite, file: parsed, relaunch: this._relaunchChoice,
    });
    const res = await this._request('POST', '/defaults', body);
    if (!res.ok) { this._showNotice(res.status, res.json); return; }
    this._clearNotice();
    const n = res.json.written;
    // An import that wasn't relaunched either was all live keys, or ran
    // with relaunch off — say live only for the first.
    this._stored(`Imported ${n} ${n === 1 ? 'value' : 'values'}`,
      this.relaunch ? null : '', !!res.json.relaunched);
    this._load();
  }

  async _replaceData(key, file) {
    const bytes = new Uint8Array(await file.arrayBuffer());
    let binary = '';
    for (let i = 0; i < bytes.length; i += 0x8000) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    this._write(key, 'data', btoa(binary));
  }

  // MARK: - events

  _onClick(e) {
    const button = e.target.closest('[data-act]');
    if (!button || !this.host.contains(button)) return;
    const item = button.closest('.df-item');
    const key = item && item.dataset.key;
    const row = key && this.rows.find((r) => r.key === key);
    switch (button.dataset.act) {
      case 'toggle': this._write(key, 'bool', !row.checked); break;
      case 'expand': this.open = this.open === key ? null : key; this._render(); break;
      case 'save': this._write(key, row.type, item.querySelector('textarea').value); break;
      case 'replace': this._replaceKey = key; this._$('.df-data-file').click(); break;
      case 'delete': this._delete(key); break;
      case 'reload': this._load(); break;
      case 'toggle-unset': {
        const lookup = this.unset.find((r) => r.key === key);
        this._write(key, 'bool', !lookup.checked);
        break;
      }
      case 'discover':
        this._request('POST', `/relaunch?${this._R.query({ bundleId: this.bundleId })}`)
          .then((res) => {
            if (!res.ok) { this._showNotice(res.status, res.json); return; }
            this._status(`Relaunched ${this._appName()}`);
            this._reloadOnceAnswered();
          });
        break;
      case 'add': this._add(); break;
      case 'export': this._export(); break;
      case 'import': this._$('.df-import-file').click(); break;
      case 'relaunch':
        this.relaunch = !this.relaunch;
        button.setAttribute('aria-checked', String(this.relaunch));
        break;
      case 'relaunch-now':
        this._request('POST', `/relaunch?${this._R.query({ bundleId: this.bundleId })}`)
          .then((res) => {
            if (!res.ok) { this._showNotice(res.status, res.json); return; }
            this._status(`Relaunched ${this._appName()}`);
            this._reloadOnceAnswered();
          });
        break;
      case 'boot':
        this._request('POST', '/boot').then(() => this._loadApps());
        break;
      default: break;
    }
  }

  _onChange(e) {
    const t = e.target;
    if (t.id === 'dfApp') { this._selectApp(t.value); return; }
    if (t.id === 'dfSuite') {
      const other = t.value === OTHER;
      this._$('.df-other').hidden = !other;
      if (other) { this._$('#dfOther').focus(); return; }
      this.suite = t.value || null;
      this.open = null;
      this._load();
      return;
    }
    if (t.id === 'dfOther') {
      this.suite = t.value.trim() || null;
      this.open = null;
      this._load();
      return;
    }
    if (t.matches('.df-new-type')) {
      this._$('.df-new-value').placeholder = PLACEHOLDERS[t.value] || '';
      return;
    }
    if (t.dataset.act === 'edit-unset') {
      const item = t.closest('.df-item');
      const lookup = this.unset.find((r) => r.key === item.dataset.key);
      const picked = item.querySelector('.df-pick-type');
      if (t.value === '') return;
      this._write(lookup.key, picked ? picked.value : lookup.type, t.value);
      return;
    }
    if (t.matches('.df-pick-type')) {
      t.closest('.df-item').querySelector('.df-value').placeholder = PLACEHOLDERS[t.value] || '';
      return;
    }
    if (t.dataset.act === 'edit') {
      const key = t.closest('.df-item').dataset.key;
      const row = this.rows.find((r) => r.key === key);
      this._write(key, row.type, t.value);
      return;
    }
    if (t.matches('.df-import-file') && t.files[0]) {
      this._import(t.files[0]);
      t.value = '';
      return;
    }
    if (t.matches('.df-data-file') && t.files[0] && this._replaceKey) {
      this._replaceData(this._replaceKey, t.files[0]);
      t.value = '';
    }
  }
}

if (typeof window !== 'undefined') window.DefaultsPanel = DefaultsPanel;

export { DefaultsPanel };
