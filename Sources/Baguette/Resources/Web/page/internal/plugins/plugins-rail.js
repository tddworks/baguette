// page/internal/plugins/plugins-rail.js — renders plugin contributions in focus mode.
//
// Plugins live in their OWN rail on the right edge, deliberately apart
// from the device toolbar. Baguette ships the toolbar; plugins are
// third-party code you installed. Keeping them physically separate is
// a trust signal, not decoration: you should always be able to tell
// "baguette did this" from "something I installed did this", and a
// plugin button must never be able to impersonate a core control.
//
// The host owns every pixel. A plugin ships a manifest describing what
// it wants (a titled panel, an icon from baguette's own set, a list
// fed by one of its commands); this file draws it with host markup.
// Nothing a plugin ships is ever loaded into this page — no plugin
// <script>, no plugin CSS, no plugin HTML. Every string from
// /plugins.json goes through escapeHTML or textContent.
//
// That constraint is what keeps the ~70 lines of Origin /
// Sec-Fetch-Site / DNS-rebind checks on the server meaningful: a
// same-origin plugin script would make all of it moot.
//
// Wire:
//   GET  /plugins.json                        → manifests
//   POST /plugins/<id>/commands/<cmd>?udid=   → {"ok",…,"rows":[…]}
// Glyphs matching Plugins/Plugin/PanelBody.swift's `PluginIcon`. A
// manifest names one; it can never supply markup. Keep the two in
// sync — an icon the host doesn't have is rejected at parse time, so
// a missing case here means a plugin that validated can't render.
import { PluginRowAction } from './plugin-row-action.js';
import { PluginPrompt } from './plugin-prompt.js';
import { PluginControl } from './plugin-control.js';

const ICONS = {
  accessibility: '<circle cx="12" cy="4.5" r="1.8"/><path d="M4.5 8.5h15M12 8v6M12 14l-3.5 6M12 14l3.5 6"/>',
  reload:        '<path d="M20 12a8 8 0 1 1-2.4-5.7"/><path d="M20 4v5h-5"/>',
  link:          '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 1 0-5.7-5.7L11.5 7"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3A4 4 0 1 0 11 18.7l1.5-1.5"/>',
  list:          '<line x1="8" y1="7" x2="20" y2="7"/><line x1="8" y1="12" x2="20" y2="12"/><line x1="8" y1="17" x2="20" y2="17"/><circle cx="4.5" cy="7" r="1"/><circle cx="4.5" cy="12" r="1"/><circle cx="4.5" cy="17" r="1"/>',
  bell:          '<path d="M18 8a6 6 0 1 0-12 0c0 6-2 7-2 7h16s-2-1-2-7"/><path d="M13.7 20a2 2 0 0 1-3.4 0"/>',
  wrench:        '<path d="M14.7 6.3a4 4 0 0 0 5 5l-9 9a2.8 2.8 0 1 1-4-4z"/>',
  lock:          '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
  globe:         '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 3 2.5 15 0 18M12 3c-2.5 3-2.5 15 0 18"/>',
  camera:        '<rect x="3" y="6.5" width="13" height="11" rx="2"/><path d="M16 10.5 21 8v8l-5-2.5z"/>',
  clock:         '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3.5 2"/>',
  document:      '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/>',
  play:          '<path d="M8 5.5v13l11-6.5z"/>',
  // Also what the host resolves an unrecognised icon name to, so a
  // plugin naming a glyph added after this build still draws
  // something deliberate. Defined below, wired in after PUZZLE.
  puzzle:        '',
};

// The rail's own emblem — a puzzle piece. Names the rail as "the
// plugins system" so the group reads as distinct from the toolbar.
const PUZZLE =
  '<path d="M10 4.5a2 2 0 0 1 4 0c0 .3-.1.6-.2.9.2-.1.5-.1.7-.1h1.5a1 1 0 0 1 1 1v1.5c0 .2 0 .5-.1.7.3-.1.6-.2.9-.2a2 2 0 0 1 0 4c-.3 0-.6-.1-.9-.2.1.2.1.5.1.7v2.5a1 1 0 0 1-1 1h-2.5c-.2 0-.5 0-.7-.1.1.3.2.6.2.9a2 2 0 0 1-4 0c0-.3.1-.6.2-.9-.2.1-.5.1-.7.1H6a1 1 0 0 1-1-1v-2.5c0-.2 0-.5.1-.7-.3.1-.6.2-.9.2a2 2 0 0 1 0-4c.3 0 .6.1.9.2C5 8.6 5 8.3 5 8.1V6.4a1 1 0 0 1 1-1h1.5c.2 0 .5 0 .7.1-.1-.3-.2-.6-.2-.9z"/>';

ICONS.puzzle = PUZZLE;

// The severities the stylesheet draws a dot for. Anything else — a
// level from a newer manifest, or a typo — falls back to `info`
// rather than reaching the page as an unrecognised attribute value.
const SEVERITIES = ['info', 'warn', 'error'];

function escapeHTML(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function svgWrap(inner, size) {
  const n = size || 17;
  return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" '
       + 'stroke-linecap="round" stroke-linejoin="round" width="' + n + '" height="' + n
       + '" aria-hidden="true">' + inner + '</svg>';
}

const iconSVG = (name) => svgWrap(ICONS[name] || ICONS.list, 17);

class PluginPanels {
  /**
   * @param {object} opts
   * @param {string} opts.udid
   * @param {HTMLElement} [opts.mount]     where the rail + panel attach (default document.body)
   * @param {HTMLElement} [opts.modalMount] where the add-a-bakery modal attaches (default `mount`)
   * @param {() => boolean} [opts.isBooted]
   * @param {(frame:object|null) => void} [opts.onHighlight]
   * @param {(point:{x:number,y:number}) => void} [opts.onTap]  device points
   * @param {(msg:string) => void} [opts.log]
   */
  constructor({ udid, mount, modalMount, isBooted, onHighlight, onTap, log }) {
    this.udid = udid;
    this.mount = mount || document.body;
    // The modal covers the page, so it cannot hang off the rail.
    // `.right-rails` is `position: fixed`, and a fixed element is a
    // stacking context whatever its `z-index` says — so everything
    // mounted inside it composites at the rail's level, and the
    // modal's `z-index: 60` was being measured against its siblings
    // in the rail rather than against the page. The device's screen
    // area sits at `z-index: 2` a level up, which is how a scrim
    // meant to cover the phone ended up painting behind it.
    this.modalMount = modalMount || this.mount;
    this.isBooted = isBooted || (() => true);
    this.onHighlight = onHighlight || (() => {});
    this.onTap = onTap || (() => {});
    this.log = log || (() => {});
    this.plugins = [];
    this.openPanelID = null;
    // What's typed in the open panel's prompt, if it has one. Held
    // here rather than read off the DOM because every command answer
    // re-renders the card — losing what you typed on the round trip
    // would make "tweak the path and fire again" impossible.
    this.promptValue = '';
    // Whether the field should hold focus after a render. Stays false
    // through the "Running…" placeholder — grabbing focus before
    // there's a field to type into would just bounce — and is set once
    // the panel's first answer draws one. You opened a panel with a
    // text field to type in it.
    this.promptFocused = false;
    this.openPluginName = null;
    // The rows the open panel last returned, kept so `filter` can
    // narrow them without re-running the command.
    this.rows = [];
    // Local tick state for a panel with controls: `{value: bool}`.
    // Diverges from the rows' reported state between a tick and the
    // Apply that confirms it, which is exactly what marks a row
    // pending. Rebuilt from every fresh answer.
    this.ticks = {};
    this.rail = null;
    this.host = null;
    // The hover flyout: at most one open, owned by one group button.
    this.flyout = null;
    this.flyoutGroup = null;
    this.flyoutButton = null;
    this.flyoutCloseTimer = null;
    this.onFlyoutKeydown = (event) => { if (event.key === 'Escape') this.closeFlyout(); };
  }

  /**
   * Fetch the contributed panels and draw the rail.
   *
   * `keepRailOnFailure` separates two different failures. On a cold
   * start, an unreachable `/plugins.json` means this server has no
   * plugin support and the right answer is to mount nothing. On a
   * *reload* the rail was already on screen and the user is mid-task
   * — dropping it there would take away the "+" button, which is the
   * only in-browser way to add a plugin, with nothing but a page
   * refresh to bring it back.
   */
  async load({ keepRailOnFailure = false } = {}) {
    let payload;
    try {
      const res = await fetch('/plugins.json', { cache: 'no-cache' });
      if (!res.ok) throw new Error('plugins.json: ' + res.status);
      payload = await res.json();
    } catch (_) {
      if (!keepRailOnFailure) return; // no server-side plugins; nothing to mount
      payload = null;
    }
    this.plugins = (payload && payload.plugins) || [];
    this.render();
  }

  /**
   * The plugins that have something to show right now, each with the
   * panels it currently contributes.
   *
   * One plugin is one rail slot, however many tools it ships. A
   * plugin with eight panels used to spend eight slots and nothing
   * said the eight belonged together; grouping by the contributing
   * plugin makes the rail's length a count of what you installed,
   * not of what those things happen to contribute.
   */
  visibleGroups() {
    const out = [];
    for (const plugin of this.plugins) {
      const panels = (plugin.panels || []).filter(
        (panel) => !(panel.when === 'simulator.booted' && !this.isBooted())
      );
      if (!panels.length) continue;   // nothing to show ⇒ no slot
      out.push({ name: plugin.name, icon: plugin.icon, panels });
    }
    return out;
  }

  render() {
    this.buildRail();
    for (const group of this.visibleGroups()) this.addGroup(group);
    // The "+ Add" entry point always shows, so a fresh user with no
    // plugins can still add their first bakery from the browser.
    this.addAddButton();
  }

  /// Tear the rail down and re-fetch — used after an install so the
  /// new plugin's button appears without a page reload.
  async reload() {
    this.closeFlyout();
    if (this.rail) this.rail.remove();
    if (this.host) this.host.remove();
    this.rail = null;
    this.host = null;
    this.openPanelID = null;
    await this.load({ keepRailOnFailure: true });
  }

  buildRail() {
    const rail = document.createElement('aside');
    rail.className = 'plugin-rail';
    rail.setAttribute('aria-label', 'Plugins');
    // Emblem cap — labels the whole strip as the plugins system.
    const cap = document.createElement('div');
    cap.className = 'plugin-rail-cap';
    cap.title = 'Plugins';
    cap.innerHTML = svgWrap(PUZZLE, 16);
    rail.appendChild(cap);
    const divider = document.createElement('div');
    divider.className = 'plugin-rail-divider';
    rail.appendChild(divider);

    const host = document.createElement('div');
    host.className = 'plugin-host';
    host.hidden = true;

    this.mount.appendChild(rail);
    this.mount.appendChild(host);
    this.rail = rail;
    this.host = host;
  }

  /**
   * One rail slot for one plugin.
   *
   * A plugin contributing a single panel keeps the old behaviour —
   * click opens it. Making you hover, wait, and then pick the only
   * item would be ceremony over a button. Only a plugin with more
   * than one tool earns the flyout.
   */
  addGroup(group) {
    const button = document.createElement('button');
    button.className = 'plugin-rail-btn';
    // The icon is a host-owned constant chosen by name — the only
    // markup here, and it never contains plugin input. The server
    // resolves which glyph represents the plugin (`Plugin.railIcon`),
    // so a plugin with no icon of its own already arrives wearing its
    // first panel's; the puzzle piece is the last resort.
    button.innerHTML = group.icon ? iconSVG(group.icon) : svgWrap(PUZZLE, 17);

    const single = group.panels.length === 1 ? group.panels[0] : null;
    // title / setAttribute, never innerHTML, for manifest text.
    if (single) {
      button.title = single.title + ' — ' + group.name;
      button.setAttribute('aria-label', single.title + ' (' + group.name + ')');
      button.addEventListener('click', () => this.toggle(group, single));
    } else {
      button.classList.add('plugin-rail-group');
      button.title = group.name + ' — ' + group.panels.length + ' tools';
      button.setAttribute('aria-label', group.name + ', ' + group.panels.length + ' tools');
      button.setAttribute('aria-haspopup', 'menu');
      button.setAttribute('aria-expanded', 'false');
      // Hover opens it; click and keyboard focus do too, so the rail
      // stays usable on a trackpad-less touch screen and by tab.
      button.addEventListener('mouseenter', () => this.openFlyout(group, button));
      button.addEventListener('mouseleave', () => this.scheduleFlyoutClose());
      button.addEventListener('focus', () => this.openFlyout(group, button));
      button.addEventListener('click', () => {
        if (this.flyoutGroup === group.name) this.closeFlyout();
        else this.openFlyout(group, button);
      });
    }

    group.button = button;
    this.rail.appendChild(button);
  }

  // --- the flyout ---------------------------------------------------
  //
  // Opens to the LEFT of the rail, aligned to the group button, and
  // lists each tool with its icon *and* its name. Icons alone stop
  // telling a plugin's tools apart once there are more than two or
  // three of them — the label is the point of the expansion.

  openFlyout(group, button) {
    this.cancelFlyoutClose();
    if (this.flyoutGroup === group.name) return;   // already showing
    this.closeFlyout();

    const flyout = document.createElement('div');
    flyout.className = 'plugin-flyout';
    flyout.setAttribute('role', 'menu');
    flyout.setAttribute('aria-label', group.name);

    const head = document.createElement('div');
    head.className = 'plugin-flyout-head';
    head.textContent = group.name;   // manifest text → textContent, never markup
    flyout.appendChild(head);

    for (const panel of group.panels) {
      const item = document.createElement('button');
      item.className = 'plugin-flyout-item';
      item.setAttribute('role', 'menuitem');
      if (this.openPanelID === panel.id) item.classList.add('active');

      const glyph = document.createElement('span');
      glyph.className = 'plugin-flyout-glyph';
      glyph.innerHTML = iconSVG(panel.icon);       // host constant
      const label = document.createElement('span');
      label.className = 'plugin-flyout-label';
      label.textContent = panel.title;             // untrusted → textContent
      item.appendChild(glyph);
      item.appendChild(label);

      item.addEventListener('click', () => {
        this.toggle(group, panel);
        this.closeFlyout();
      });
      flyout.appendChild(item);
    }

    flyout.addEventListener('mouseenter', () => this.cancelFlyoutClose());
    flyout.addEventListener('mouseleave', () => this.scheduleFlyoutClose());
    this.mount.appendChild(flyout);

    this.flyout = flyout;
    this.flyoutGroup = group.name;
    this.flyoutButton = button;
    button.setAttribute('aria-expanded', 'true');
    button.classList.add('expanded');
    document.addEventListener('keydown', this.onFlyoutKeydown);
    this.positionFlyout(flyout, button);
  }

  /// Centre the flyout on its button, then keep it on screen — a
  /// group near the top or bottom of a short window would otherwise
  /// hang off the edge.
  positionFlyout(flyout, button) {
    const rail = this.rail.getBoundingClientRect();
    const anchor = button.getBoundingClientRect();
    flyout.style.right = (window.innerWidth - rail.left + 8) + 'px';
    const height = flyout.offsetHeight;
    const centred = anchor.top + anchor.height / 2 - height / 2;
    const clamped = Math.max(12, Math.min(centred, window.innerHeight - height - 12));
    flyout.style.top = clamped + 'px';
  }

  /// A grace period so travelling from the button to the flyout
  /// across the 8px gap doesn't dismiss what you're reaching for.
  scheduleFlyoutClose() {
    this.cancelFlyoutClose();
    this.flyoutCloseTimer = setTimeout(() => this.closeFlyout(), 160);
  }

  cancelFlyoutClose() {
    if (this.flyoutCloseTimer) clearTimeout(this.flyoutCloseTimer);
    this.flyoutCloseTimer = null;
  }

  closeFlyout() {
    this.cancelFlyoutClose();
    if (this.flyoutButton) {
      this.flyoutButton.setAttribute('aria-expanded', 'false');
      this.flyoutButton.classList.remove('expanded');
    }
    if (this.flyout) this.flyout.remove();
    this.flyout = null;
    this.flyoutGroup = null;
    this.flyoutButton = null;
    document.removeEventListener('keydown', this.onFlyoutKeydown);
  }

  /// A "+" at the foot of the rail that opens the plugins modal —
  /// what your bakeries offer, and the field for previewing a new one.
  addAddButton() {
    const divider = document.createElement('div');
    divider.className = 'plugin-rail-divider';
    this.rail.appendChild(divider);

    const button = document.createElement('button');
    button.className = 'plugin-rail-btn plugin-rail-add';
    button.title = 'Plugins — install from your bakeries, or add one';
    button.setAttribute('aria-label', 'Plugins');
    button.innerHTML = svgWrap('<path d="M12 5v14M5 12h14"/>', 18);
    button.addEventListener('click', () => this.openPluginsModal());
    this.rail.appendChild(button);
  }

  /// The rail highlights the *plugin* whose panel is open, not the
  /// panel — the panel no longer has a slot of its own to light up.
  toggle(group, panel) {
    if (this.openPanelID === panel.id) { this.close(); return; }
    for (const b of this.rail.querySelectorAll('.plugin-rail-btn')) {
      b.classList.toggle('active', b === group.button);
    }
    this.open(group.name, panel);
  }

  close() {
    this.openPanelID = null;
    this.openPluginName = null;
    this.promptValue = '';
    this.promptFocused = false;
    this.rows = [];
    this.ticks = {};
    // What's been submitted from this panel's prompt, newest first,
    // and where ↑/↓ currently sits in it (-1 = not browsing).
    this.history = [];
    this.historyAt = -1;
    // Escape hides the ghost without clearing the field; typing again
    // brings it back.
    this.ghostSuppressed = false;
    this.host.innerHTML = '';
    this.host.hidden = true;
    this.onHighlight(null);
    for (const b of this.rail.querySelectorAll('.plugin-rail-btn')) b.classList.remove('active');
  }

  async open(pluginName, panel) {
    this.openPanelID = panel.id;
    this.openPluginName = pluginName;
    this.host.hidden = false;
    // A fresh panel starts with an empty field and no rows; carrying
    // the last panel's text across would submit it to a different
    // plugin's command. Switching panels goes straight through here
    // without passing `close`, so this is the only place that runs.
    this.promptValue = '';
    this.promptFocused = false;
    this.rows = [];
    this.ticks = {};
    this.historyAt = -1;
    this.ghostSuppressed = false;
    this.history = this.promptFor(panel).remembers ? this.loadHistory(panel) : [];
    this.renderShell(pluginName, panel, '<div class="plugin-status">Running…</div>');

    const body = panel.body || {};
    if (body.kind !== 'list') {
      this.renderShell(pluginName, panel, '<div class="plugin-status">Unsupported panel</div>');
      return;
    }

    const [id, cmd] = String(body.source).split(':');
    await this.invoke(pluginName, panel, id, cmd, null);
  }

  /// The panel's declared text field, as a decision object. Absent for
  /// every panel that doesn't declare one, which is all of them until
  /// a manifest opts in.
  promptFor(panel) {
    return new PluginPrompt((panel.body || {}).prompt);
  }

  // --- inline completion + history ----------------------------------

  /// Where history lives: per panel, so the deep-link bar and a
  /// settings panel don't arrow through each other's entries.
  historyKey(panel) {
    return 'baguette.plugin-prompt.' + String(panel.id || '');
  }

  /// Reading is defensive because `localStorage` throws outright in
  /// private mode and in some embedded webviews — a bar that can't
  /// remember must still type.
  loadHistory(panel) {
    try {
      const raw = window.localStorage.getItem(this.historyKey(panel));
      const parsed = raw ? JSON.parse(raw) : [];
      return Array.isArray(parsed) ? parsed.filter((e) => typeof e === 'string') : [];
    } catch (_) {
      return [];
    }
  }

  saveHistory(panel, history) {
    try {
      window.localStorage.setItem(this.historyKey(panel), JSON.stringify(history));
    } catch (_) { /* full, or storage denied — not worth failing a click over */ }
  }

  /// What the bar may complete to: what you've used, then what the
  /// plugin listed. Filtered rows only, so the ghost never offers
  /// something the list is currently hiding.
  promptCandidates(panel) {
    const prompt = this.promptFor(panel);
    const visible = this.rows.filter((row) => prompt.matches(row, this.promptValue));
    return prompt.candidates(visible, this.history);
  }

  promptGhost(panel) {
    if (this.ghostSuppressed) return '';
    return this.promptFor(panel).ghost(this.promptValue, this.promptCandidates(panel));
  }

  /**
   * Draw the un-typed remainder behind the field.
   *
   * The typed prefix is rendered too, but transparent — that's what
   * makes the remainder line up with the caret without measuring text.
   * Both halves go in via `textContent`, so a plugin's row text can't
   * become markup on the way.
   */
  paintGhost(panel) {
    const ghost = this.host.querySelector('.plugin-prompt-ghost');
    if (!ghost) return;
    ghost.textContent = '';
    const rest = this.promptGhost(panel);
    if (!rest) return;

    const typed = document.createElement('span');
    typed.className = 'plugin-prompt-typed';
    typed.textContent = this.promptValue;
    const remainder = document.createElement('span');
    remainder.className = 'plugin-prompt-rest';
    remainder.textContent = rest;
    ghost.appendChild(typed);
    ghost.appendChild(remainder);
  }

  /**
   * Step through what's been submitted before. `↑` goes older.
   *
   * Stepping back past the newest entry restores the field to empty
   * rather than sticking on the first one, so arrowing up and back
   * down leaves you where you started.
   */
  recallHistory(panel, direction) {
    if (!this.history.length) return;
    const next = Math.min(this.history.length - 1, Math.max(-1, this.historyAt + direction));
    this.historyAt = next;
    this.promptValue = next < 0 ? '' : this.history[next];
    // A recalled value is a whole entry, so a ghost completing it
    // further would be suggesting something you didn't ask for.
    this.ghostSuppressed = true;
    const input = this.host.querySelector('.plugin-prompt-input');
    if (input) {
      input.value = this.promptValue;
      input.setSelectionRange(this.promptValue.length, this.promptValue.length);
    }
    this.paintGhost(panel);
    if (this.promptFor(panel).filters) {
      this.paintRows(panel, (panel.body || {}).rowAction);
    }
  }

  /**
   * Put a row's text into the prompt and leave the caret after it.
   *
   * The point is to keep typing, so this deliberately does **not**
   * submit: `account://` on its own is a scheme with no path, which is
   * almost never what anyone means to open. The field becomes what you
   * picked, and Enter is still yours to press.
   */
  fillPrompt(panel, text, rowAction) {
    this.promptValue = text;
    this.promptFocused = true;
    // Picking a row is a fresh intent, so a ghost dismissed earlier is
    // welcome again — it's how you get from `account://` to the path
    // you used last time in one more keystroke.
    this.ghostSuppressed = false;
    this.historyAt = -1;
    const input = this.host.querySelector('.plugin-prompt-input');
    if (input) {
      input.value = text;
      input.focus();
      input.setSelectionRange(text.length, text.length);
    }
    this.paintGhost(panel);
    // Repaint the rows against the new filter value, but never through
    // renderShell — that would rebuild the field and drop the caret we
    // just placed.
    if (this.promptFor(panel).filters) this.paintRows(panel, rowAction);
  }

  /**
   * Submit the prompt: run the panel's own `source` command with what
   * was typed. Identical to a `rowAction: "run"` click — same body,
   * same endpoint — so the panel re-renders from what the command
   * actually answered rather than from what the submit assumed.
   */
  submitPrompt(pluginName, panel) {
    const prompt = this.promptFor(panel);
    const args = prompt.args(this.promptValue);
    if (!args) return;   // nothing typed; don't spend a subprocess
    // Remembered on submit rather than on success: you typed it and
    // meant it, and a link that failed is exactly the one you want to
    // arrow back to and fix.
    if (prompt.remembers) {
      this.history = prompt.remember(this.history, this.promptValue);
      this.historyAt = -1;
      this.saveHistory(panel, this.history);
    }
    const [id, cmd] = String((panel.body || {}).source || '').split(':');
    this.renderShell(pluginName, panel, '<div class="plugin-status">Running…</div>');
    this.invoke(pluginName, panel, id, cmd, args);
  }

  /**
   * Run one of a plugin's commands and render the answer into the
   * open panel. Both the panel's own `source` and a `rowAction:
   * "run"` click land here, so a row that changes something re-renders
   * from the command's fresh output rather than from what the browser
   * assumed would happen.
   *
   * @param {string} id       plugin id
   * @param {string} cmd      command id within that plugin
   * @param {object|null} args  arguments from the clicked row, if any
   */
  async invoke(pluginName, panel, id, cmd, args) {
    const body = panel.body || {};
    let payload;
    try {
      const url = '/plugins/' + encodeURIComponent(id) + '/commands/' + encodeURIComponent(cmd)
                + '?udid=' + encodeURIComponent(this.udid);
      const init = { method: 'POST' };
      if (args) {
        init.headers = { 'content-type': 'application/json' };
        init.body = JSON.stringify({ args });
      }
      const res = await fetch(url, init);
      payload = await res.json();
    } catch (error) {
      this.renderShell(pluginName, panel, this.statusHTML('Could not reach the server: ' + error));
      return;
    }
    // Guard against a slow response landing after the user moved on.
    if (this.openPanelID !== panel.id) return;

    if (!payload.ok) {
      this.renderShell(pluginName, panel,
        this.statusHTML(payload.error || payload.message || 'Plugin failed'));
      return;
    }
    this.renderRows(pluginName, panel, payload.rows || [], body.rowAction);
  }

  /**
   * Copy a row's text, and say so when the browser won't.
   *
   * `navigator.clipboard` is undefined outside a secure context, and
   * while `127.0.0.1` counts as secure, `serve` accepts
   * `--allowed-hosts` — so the page can be reached by hostname over
   * plain http, where this is simply absent. Calling it there throws
   * inside the click handler and the row just looks selected with
   * nothing on the clipboard. `writeText` can also reject on a
   * permission failure, which was likewise unhandled.
   */
  copyToClipboard(text, row) {
    const clipboard = navigator.clipboard;
    if (!clipboard || typeof clipboard.writeText !== 'function') {
      this.noteRowError(row, 'clipboard needs https or localhost');
      return;
    }
    clipboard.writeText(text).catch((error) => {
      this.noteRowError(row, String((error && error.message) || error));
    });
  }

  /** A short-lived note on one row, for a failure that isn't the panel's. */
  noteRowError(row, message) {
    if (!row) return;
    const previous = row.querySelector('.plugin-inline-error');
    if (previous) previous.remove();
    const note = document.createElement('span');
    note.className = 'plugin-error plugin-inline-error';
    note.textContent = ' ' + message;
    row.appendChild(note);
    setTimeout(() => note.remove(), 4000);
  }

  statusHTML(message) {
    return '<div class="plugin-status plugin-error">' + escapeHTML(message) + '</div>';
  }

  renderShell(pluginName, panel, innerHTML) {
    const prompt = this.promptFor(panel);
    const control = this.controlFor(panel);
    this.host.innerHTML =
      '<div class="plugin-card">'
      + '<div class="plugin-head">'
      +   '<span class="plugin-title">' + escapeHTML(panel.title) + '</span>'
      +   '<span class="plugin-tag">' + escapeHTML(pluginName) + '</span>'
      +   '<button class="plugin-close" aria-label="Close">✕</button>'
      + '</div>'
      + '<div class="plugin-body">'
      +   (prompt.present ? '<div class="plugin-prompt"></div>' : '')
      +   innerHTML
      + '</div>'
      // Outside `.plugin-body` so it stays put while the rows scroll —
      // a submit button you have to scroll to find is one you forget
      // to press, which with batching means losing the edit.
      + (control.present ? '<div class="plugin-apply"></div>' : '')
      + '</div>';
    const close = this.host.querySelector('.plugin-close');
    if (close) close.addEventListener('click', () => this.close());
    if (prompt.present) this.mountPrompt(pluginName, panel, prompt);
    if (control.present) this.mountApply(pluginName, panel, control);
  }

  /**
   * The batch-submit button, at the foot of a panel with controls.
   *
   * It says how many rows are waiting, because the whole cost of
   * batching is that those rows are showing something the device
   * hasn't confirmed — and a button that didn't count them would let
   * you close the panel believing you'd applied something.
   */
  mountApply(pluginName, panel, control) {
    const slot = this.host.querySelector('.plugin-apply');
    if (!slot) return;

    const button = document.createElement('button');
    button.className = 'plugin-btn plugin-apply-btn';
    slot.appendChild(button);
    button.addEventListener('click', () => this.submitTicks(pluginName, panel, control));
    this.paintApplyButton(panel);
  }

  /// Keep the button's label and enabled state honest as ticks change.
  paintApplyButton(panel) {
    const button = this.host.querySelector('.plugin-apply-btn');
    if (!button) return;
    const control = this.controlFor(panel);
    const waiting = control.pending(this.ticks, this.rows).length;
    button.textContent = waiting
      ? control.submitLabel + ' (' + waiting + ')'
      : control.submitLabel;
    // Nothing pending means nothing to say to the device. Disabled
    // rather than hidden, so the button doesn't appear and vanish
    // under the cursor as you tick and untick.
    button.disabled = waiting === 0;
    const slot = this.host.querySelector('.plugin-apply');
    if (slot) slot.classList.toggle('plugin-apply-dirty', waiting > 0);
  }

  /**
   * Send every ticked value at once, then re-render from the answer.
   *
   * The panel deliberately does not keep its local ticks afterwards:
   * `renderRows` rebuilds them from what the plugin reports, so a
   * setting the device refused snaps back to the truth instead of
   * staying stuck the way it was clicked.
   */
  submitTicks(pluginName, panel, control) {
    const args = control.args(this.ticks, this.rows);
    if (!args) return;
    const [id, cmd] = String((panel.body || {}).source || '').split(':');
    this.renderShell(pluginName, panel, '<div class="plugin-status">Applying…</div>');
    this.invoke(pluginName, panel, id, cmd, args);
  }

  /**
   * Build the text field with DOM calls rather than an HTML string.
   *
   * `placeholder` and the button label come from a manifest, which is
   * untrusted text destined for the origin `isTrustedBrowserRequest`
   * spends ~70 lines defending — so they go in via `setAttribute` and
   * `textContent`, never `innerHTML`. Same rule as every other
   * manifest string in this file.
   */
  mountPrompt(pluginName, panel, prompt) {
    const slot = this.host.querySelector('.plugin-prompt');
    if (!slot) return;

    // The ghost sits *behind* the input, sharing its metrics, with the
    // typed prefix rendered transparent so only the remainder shows.
    // An overlay rather than a second value in the field itself, which
    // would put text the user hasn't accepted into what Enter submits.
    const field = document.createElement('div');
    field.className = 'plugin-prompt-field';
    const ghost = document.createElement('div');
    ghost.className = 'plugin-prompt-ghost';
    ghost.setAttribute('aria-hidden', 'true');

    const input = document.createElement('input');
    input.className = 'plugin-prompt-input';
    input.type = 'text';
    input.spellcheck = false;
    input.setAttribute('placeholder', prompt.placeholder);
    input.setAttribute('aria-label', panel.title);
    input.value = this.promptValue;

    const go = document.createElement('button');
    go.className = 'plugin-btn plugin-prompt-go';
    go.textContent = prompt.submitLabel;

    field.appendChild(ghost);
    field.appendChild(input);
    slot.appendChild(field);
    slot.appendChild(go);

    const rowAction = (panel.body || {}).rowAction;
    const retype = () => {
      this.promptValue = input.value;
      this.paintGhost(panel);
      if (prompt.filters) this.paintRows(panel, rowAction);
    };

    input.addEventListener('input', () => {
      // Typing leaves history browsing — otherwise the next ↑ would
      // jump from a value you've since edited.
      this.historyAt = -1;
      // And it revives a ghost dismissed with Escape or stood down by
      // a history recall. Suppression is about *that* value; once you
      // type a different one there's a fresh suggestion to make, and
      // leaving the flag set silently killed completion for the rest
      // of the session.
      this.ghostSuppressed = false;
      retype();
    });
    input.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') { this.submitPrompt(pluginName, panel); return; }

      // Accept the ghost. `→` only counts at the very end of the
      // field, so moving the caret through what you typed still moves
      // the caret.
      const atEnd = input.selectionStart === input.value.length
                 && input.selectionEnd === input.value.length;
      if ((event.key === 'Tab' || (event.key === 'ArrowRight' && atEnd))
          && this.promptGhost(panel)) {
        event.preventDefault();
        input.value = prompt.accepted(input.value, this.promptCandidates(panel));
        retype();
        return;
      }

      if ((event.key === 'ArrowUp' || event.key === 'ArrowDown') && prompt.remembers) {
        event.preventDefault();
        this.recallHistory(panel, event.key === 'ArrowUp' ? 1 : -1);
        return;
      }

      // Give up the suggestion without giving up what you typed.
      if (event.key === 'Escape' && this.promptGhost(panel)) {
        event.preventDefault();
        this.ghostSuppressed = true;
        this.paintGhost(panel);
      }
    });
    go.addEventListener('click', () => this.submitPrompt(pluginName, panel));
    this.paintGhost(panel);

    // Re-focus after a re-render, so submitting and then typing again
    // doesn't need a click. Caret to the end rather than selecting all
    // — you're usually editing the path, not replacing the URL.
    if (this.promptFocused) {
      input.focus();
      input.setSelectionRange(input.value.length, input.value.length);
    }
  }

  renderRows(pluginName, panel, rows, rowAction) {
    this.rows = rows;
    const prompt = this.promptFor(panel);
    // A panel with a field is never "empty": the field is the point,
    // and replacing it with "Nothing to report" would take away the
    // only way to ask for something.
    if (!rows.length && !prompt.present) {
      this.renderShell(pluginName, panel, '<div class="plugin-status">Nothing to report</div>');
      return;
    }
    // The first answer is what draws the field, so this is the render
    // that may take focus — you opened a panel with a text box to type
    // in it. Every later render then restores it.
    if (prompt.present) this.promptFocused = true;
    // A fresh answer is the device's word on every control, so the
    // pending ticks it just confirmed (or refused) are replaced by it
    // rather than surviving to contradict it.
    this.ticks = this.controlFor(panel).initialTicks(rows);
    this.renderShell(pluginName, panel, this.rowsHTML(rows, rowAction, prompt, panel));
    this.wireRows(pluginName, panel, rowAction);
  }

  /// Re-draw just the row list against the current filter and ticks,
  /// leaving the field alone — repainting the whole card on every
  /// keystroke would tear down the input being typed into.
  paintRows(panel, rowAction) {
    const prompt = this.promptFor(panel);
    const list = this.host.querySelector('.plugin-rows');
    const body = this.host.querySelector('.plugin-body');
    const html = this.rowsHTML(this.rows, rowAction, prompt, panel);
    if (list) list.outerHTML = html;
    else if (body) body.insertAdjacentHTML('beforeend', html);
    this.wireRows(null, panel, rowAction);
    this.paintApplyButton(panel);
  }

  /// The panel's declared row controls, as a decision object.
  controlFor(panel) {
    return new PluginControl((panel.body || {}).control);
  }

  rowsHTML(rows, rowAction, prompt, panel) {
    const action = new PluginRowAction(rowAction);
    const control = this.controlFor(panel);
    const pending = new Set(control.pending(this.ticks, rows));
    // Carry each row's index in the *unfiltered* list, because that's
    // what the click handler looks the row up by — filtering must not
    // silently renumber which row a click resolves to.
    const visible = rows
      .map((row, index) => ({ row, index }))
      .filter(({ row }) => prompt.matches(row, this.promptValue));
    if (!visible.length) {
      return '<ul class="plugin-rows"><li class="plugin-row plugin-row-empty">'
           + '<span class="plugin-row-text"><span class="plugin-row-sub">'
           + (rows.length ? 'Nothing matches' : 'Nothing to report')
           + '</span></span></li></ul>';
    }
    const items = visible.map(({ row, index }) => {
      const severity = SEVERITIES.includes(row.severity) ? row.severity : 'info';
      const ticked = control.isControlRow(row);
      // A control row is clickable because it ticks; a plain row falls
      // through to whatever `rowAction` the panel declared. That's how
      // a settings list keeps its section headings and can still mix
      // in an ordinary action row.
      const clickable = (ticked || action.actionable(row)) ? ' plugin-row-clickable' : '';
      const unconfirmed = pending.has(row.value) ? ' plugin-row-pending' : '';
      // In a panel of controls, a plain informational row is a section
      // heading — the only thing display.py uses one for. Saying so in
      // the markup is what lets it stop competing with the ticks: an
      // `info` dot sitting in the same column as a radio reads as a
      // third, disabled control state, and once every row in the
      // gutter is a circle the hierarchy is gone. A `warn` / `error`
      // dot still draws, because that one carries real meaning.
      const heading = control.present && !ticked
        && !action.actionable(row) && severity === 'info';
      return '<li class="plugin-row' + clickable + unconfirmed
           + (heading ? ' plugin-row-heading' : '')
           + (control.present && !ticked && !heading ? ' plugin-row-inset' : '')
           + '" data-index="' + index + '">'
           + (ticked
                // The glyph is host markup driven by a boolean; the
                // manifest only ever chose which family to draw.
                ? '<span class="plugin-tick" data-control="' + control.kind + '"'
                  + ' data-on="' + (this.ticks[row.value] ? 'true' : 'false') + '"'
                  + ' role="' + (control.kind === 'radio' ? 'radio' : 'checkbox') + '"'
                  + ' aria-checked="' + (this.ticks[row.value] ? 'true' : 'false') + '"></span>'
                : heading
                    ? ''
                    : '<span class="plugin-dot" data-severity="' + severity + '"></span>')
           + '<span class="plugin-row-text">'
           +   '<span class="plugin-row-title">' + escapeHTML(row.title) + '</span>'
           +   (row.subtitle
                 ? '<span class="plugin-row-sub">' + escapeHTML(row.subtitle) + '</span>'
                 : '')
           + '</span></li>';
    }).join('');
    return '<ul class="plugin-rows">' + items + '</ul>';
  }

  /// Attach the row-click handler to whichever `.plugin-rows` is on
  /// screen now. Re-attached after each paint because filtering
  /// replaces the list element.
  wireRows(pluginName, panel, rowAction) {
    const name = pluginName || this.openPluginName;
    const action = new PluginRowAction(rowAction);
    const control = this.controlFor(panel);
    const list = this.host.querySelector('.plugin-rows');
    // A control-only panel declares no `rowAction` and still needs its
    // clicks — bailing on `!rowAction` alone would leave every tick
    // inert on exactly the panels this feature exists for.
    if (!list || (!rowAction && !control.present)) return;
    list.addEventListener('click', (event) => {
      const li = event.target.closest('.plugin-row');
      if (!li) return;
      const row = this.rows[Number(li.dataset.index)];
      if (!row) return;
      // A tickable row ticks. It costs no subprocess — the panel
      // accumulates and sends them together when Apply is pressed.
      if (control.isControlRow(row)) {
        this.ticks = control.toggle(this.ticks, row, this.rows);
        this.paintRows(panel, rowAction);
        return;
      }
      const intent = action.intent(row);
      if (!intent) return;   // an inert row stays inert, selection included
      for (const other of list.querySelectorAll('.plugin-row')) {
        other.classList.toggle('plugin-row-active', other === li);
      }
      if (intent.kind === 'highlight') this.onHighlight(intent.frame);
      if (intent.kind === 'tap') this.onTap(intent.point);
      if (intent.kind === 'copy') this.copyToClipboard(intent.text, li);
      if (intent.kind === 'fill') this.fillPrompt(panel, intent.text, rowAction);
      if (intent.kind === 'run') {
        // The row names a command within its own plugin; the plugin
        // id comes from the panel's own source, so a row can never
        // reach into a different plugin.
        const pluginID = String((panel.body || {}).source || '').split(':')[0];
        this.invoke(name, panel, pluginID, intent.command, intent.args);
      }
    });
  }

  // --- the plugins modal --------------------------------------------
  //
  // Two halves, and the split is the trust boundary.
  //
  // The shelf installs from bakeries you have **already trusted**. The
  // request names one by its recorded id, so the page can only reach a
  // source already in `bakeries.json`, at the commit pinned there.
  //
  // The field below only *previews*. Cloning a repo and reading its
  // menu is safe; trusting a new source is not something a page can
  // do for you — a modal button isn't consent, the page sets the flag
  // it then checks — so preview ends by handing you the command to
  // type. See `InstallDecision` on the Swift side.

  openPluginsModal() {
    // One at a time. Pressing "+" again used to stack a second copy
    // on the first, and because each reads the shelf when it opens,
    // the one you ended up looking at could be the stale one — it
    // showed Install for a plugin the modal underneath had already
    // installed.
    const open = this.modalMount.querySelector('.plugin-modal-overlay');
    if (open) {
      const field = open.querySelector('.plugin-input');
      if (field) field.focus();
      return;
    }

    const overlay = document.createElement('div');
    overlay.className = 'plugin-modal-overlay';
    overlay.innerHTML =
      '<div class="plugin-modal" role="dialog" aria-label="Plugins">'
      + '<div class="plugin-head">'
      +   '<span class="plugin-title">Plugins</span>'
      +   '<button class="plugin-close" aria-label="Close">✕</button>'
      + '</div>'
      + '<div class="plugin-modal-body">'
      +   '<div class="plugin-shelf"><div class="plugin-status">Reading your bakeries…</div></div>'
      +   '<div class="plugin-modal-rule"></div>'
      +   '<label class="plugin-field-label">Add a bakery — a git repo with a baguette.json</label>'
      +   '<div class="plugin-field-row">'
      +     '<input class="plugin-input" type="text" placeholder="owner/repo or a git URL" spellcheck="false">'
      +     '<button class="plugin-btn plugin-preview-btn">Preview</button>'
      +   '</div>'
      +   '<div class="plugin-modal-result"></div>'
      + '</div>'
      + '</div>';
    this.modalMount.appendChild(overlay);

    const close = () => overlay.remove();
    overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });
    overlay.querySelector('.plugin-close').addEventListener('click', close);
    void this.paintShelf(overlay.querySelector('.plugin-shelf'));

    const input = overlay.querySelector('.plugin-input');
    const result = overlay.querySelector('.plugin-modal-result');
    const button = overlay.querySelector('.plugin-preview-btn');
    // One preview at a time. A preview clones the repo, which takes
    // the better part of a minute on a cold cache with nothing on
    // screen but "Fetching…", so a second press is the natural
    // reaction — and two clones of one bakery used to fight over the
    // same cache directory until git died. The clone is safe against
    // that now; this stops the pointless second minute of network.
    // Per-modal, not per-panel: closing and reopening starts clean,
    // so a request still in flight from a dismissed modal can't leave
    // the new one's button inert. Its answer just paints into a
    // `result` element nobody is looking at any more.
    let inFlight = false;
    const preview = () => {
      if (inFlight) return;
      const ref = input.value.trim();
      if (!ref) return;
      inFlight = true;
      button.disabled = true;
      this.previewInto(ref, result, close)
          .finally(() => { inFlight = false; button.disabled = false; });
    };
    button.addEventListener('click', preview);
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') preview(); });
    input.focus();
  }

  /**
   * Draw what your trusted bakeries are offering.
   *
   * Every name here came out of some repo's `baguette.json`, so it
   * goes in as text, never markup — same rule the panel rows follow.
   * Whether a plugin counts as installed is decided server-side; the
   * page renders the answer rather than re-deriving it.
   */
  async paintShelf(shelf) {
    let data;
    try {
      const res = await fetch('/bakeries.json', { cache: 'no-cache' });
      data = await res.json();
      if (!res.ok) throw new Error(data.error || 'could not read your bakeries');
    } catch (error) {
      shelf.innerHTML = '<div class="plugin-status plugin-error">'
        + escapeHTML(String(error.message || error)) + '</div>';
      return;
    }

    const bakeries = data.bakeries || [];
    if (!bakeries.length) {
      // Not an error — the first-run state, and the field below is
      // the answer to it.
      shelf.innerHTML = '<div class="plugin-status">'
        + 'No bakeries trusted yet. Preview one below, then trust it in a terminal.'
        + '</div>';
      return;
    }

    shelf.innerHTML = '<div class="plugin-shelf-label">Your bakeries</div>'
      + bakeries.map((bakery) =>
        '<div class="plugin-source">'
        + '<div class="plugin-source-head">'
        +   '<span class="plugin-source-id">' + escapeHTML(bakery.id) + '</span>'
        +   '<span class="plugin-commit">@' + escapeHTML(String(bakery.commit || '').slice(0, 10)) + '</span>'
        + '</div>'
        + '<ul class="plugin-offers">'
        + (bakery.plugins || []).map((p) =>
            '<li class="plugin-offer">'
            + '<span class="plugin-row-title">' + escapeHTML(p.name) + '</span>'
            + (p.installed
                ? '<span class="plugin-installed">Installed</span>'
                : '<button class="plugin-btn plugin-install-btn"'
                  + ' data-bakery="' + escapeHTML(bakery.id) + '"'
                  + ' data-plugin="' + escapeHTML(p.name) + '">Install</button>')
            + '</li>').join('')
        + '</ul>'
        + '</div>').join('');

    for (const button of shelf.querySelectorAll('.plugin-install-btn')) {
      button.addEventListener('click', () => this.installOffer(button, shelf));
    }
  }

  /**
   * Install one offer, then put the rail back in step with the disk.
   *
   * An install clones the bakery at its pinned commit, so this is the
   * same minute-long wait a preview is — the button says so and stops
   * taking clicks. Only this button is disabled, not the whole shelf:
   * two installs from different bakeries don't collide, and the
   * checkout is safe against two that do.
   */
  async installOffer(button, shelf) {
    if (button.disabled) return;
    const bakery = button.dataset.bakery;
    const plugin = button.dataset.plugin;
    button.disabled = true;
    button.textContent = 'Installing…';
    try {
      const res = await fetch('/bakeries/install', {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ bakery, plugin }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'install failed');
    } catch (error) {
      button.disabled = false;
      button.textContent = 'Install';
      this.log('install failed: ' + (error.message || error));
      const note = document.createElement('div');
      note.className = 'plugin-status plugin-error';
      note.textContent = String(error.message || error);
      shelf.appendChild(note);
      return;
    }
    // Redraw from the server rather than flipping the button to
    // "Installed" here: the manifest decides the installed plugin's
    // real name, and it doesn't have to match the menu label.
    await this.paintShelf(shelf);
    // The rail is now out of date by exactly one plugin.
    await this.reload();
  }

  async previewInto(ref, result, closeModal) {
    if (!ref) return;
    result.innerHTML = '<div class="plugin-status">Fetching… this clones the repo, so a cold one takes a minute.</div>';
    let data;
    try {
      const res = await fetch('/bakeries/preview', {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ ref }),
      });
      data = await res.json();
      if (!res.ok) throw new Error(data.error || 'preview failed');
    } catch (error) {
      result.innerHTML = '<div class="plugin-status plugin-error">' + escapeHTML(String(error.message || error)) + '</div>';
      return;
    }

    const shortCommit = String(data.commit || '').slice(0, 10);
    // A preview of a source you haven't trusted ends in one command,
    // not a button. Trusting is the decision that matters — after it,
    // this bakery joins the shelf above and its plugins install from
    // there with a click. See `docs/features/plugins/README.md`.
    const trustCommand = 'baguette bakery add ' + ref;
    const rows = (data.plugins || []).map((p) =>
      '<li class="plugin-offer">'
      + '<span class="plugin-row-title">' + escapeHTML(p.name) + '</span>'
      + (data.alreadyTrusted
          ? '<span class="plugin-installed">Trusted</span>'
          : '<span class="plugin-row-sub">on the shelf once trusted</span>')
      + '</li>').join('');

    result.innerHTML =
      '<div class="plugin-warn">'
      +   '⚠ Plugins from <b>' + escapeHTML(data.name || ref) + '</b> run as programs on your Mac '
      +   'with your permissions. Only add sources you trust. '
      +   '<span class="plugin-commit">@' + escapeHTML(shortCommit) + '</span>'
      + '</div>'
      + '<ul class="plugin-offers">' + rows + '</ul>'
      + (data.alreadyTrusted
          ? '<div class="plugin-status">Already trusted — it\'s on the shelf above.</div>'
          : '<div class="plugin-field-row">'
            + '<code class="plugin-cmd">' + escapeHTML(trustCommand) + '</code>'
            + '<button class="plugin-btn plugin-copy-cmd">Copy</button>'
            + '</div>'
            + '<div class="plugin-status">Run that in a terminal to trust the source, '
            + 'then reopen this — its plugins install from the shelf above.</div>');

    for (const btn of result.querySelectorAll('.plugin-copy-cmd')) {
      btn.addEventListener('click', () => {
        const row = btn.parentElement;
        const cmd = row && row.querySelector('.plugin-cmd');
        this.copyToClipboard(cmd ? cmd.textContent : '', row);
      });
    }
  }

}

// No CSS here. The rail, its flyout and the panel are styled by the
// focus-mode stylesheet in page/device-page.html, under `#simNativeView`,
// where the --nv-* theme tokens are defined — same arrangement as the
// logs, status-bar, location and a11y panels. A stylesheet written
// beside this module can't see those tokens, so every colour in it had
// to carry a guessed fallback, and the guesses were light-theme values.

export { PluginPanels };
