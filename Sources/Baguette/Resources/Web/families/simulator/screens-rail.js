// families/simulator/screens-rail.js — the companion-screens rail in focus mode.
//
// A simulator can drive more than its own glass: a CarPlay external
// display, and the Apple Watch paired with it. Both used to be a
// standing decision the page made for you — the CarPlay pane was always
// mounted, which also meant every page load reached into Simulator.app
// and attached a CarPlay display whether you wanted one or not.
//
// This rail makes it a choice. It asks the host what is actually there
// (`/devices/<udid>/companion-screens.json`), offers what it can
// show, and for what it can't, says how to get one — a device with no
// CarPlay display and no paired watch is the common case, so "nothing
// here" has to be a useful answer rather than an empty rail.
//
// The rail owns the buttons, the state card and the remembered choice.
// It does not own the streams: opening a pane calls back into
// page/device-page.js, which owns every StreamSession on the page.
//
// Wire:
//   GET  /devices/<udid>/companion-screens.json  → what's attached
//   POST /devices/<udid>/boot                    → boot a paired watch
(function (root) {
  'use strict';

  const STORAGE_KEY = 'baguette.companionScreens';

  // Host-owned glyphs, one per companion screen. Keyed by the same ids
  // `CompanionScreens` uses so a new kind lands in one place at each end.
  const GLYPHS = {
    external:
      '<path d="M4 16.5h16M5.5 16.5v2M18.5 16.5v2"/>' +
      '<path d="M4.6 16.5 6.2 9.9A2 2 0 0 1 8.1 8.4h7.8a2 2 0 0 1 1.9 1.5l1.6 6.6"/>' +
      '<path d="M6.4 13.2h11.2"/>',
    watch:
      '<rect x="7" y="6.5" width="10" height="11" rx="3"/>' +
      '<path d="M9 6.5 9.4 3.2h5.2l.4 3.3M9 17.5l.4 3.3h5.2l.4-3.3"/>',
  };

  const RAIL_CAP =
    '<rect x="2.5" y="5" width="12" height="9" rx="2"/>' +
    '<path d="M6 18h5"/>' +
    '<rect x="16" y="10" width="5.5" height="9" rx="1.8"/>';

  function svgWrap(inner, size) {
    const n = size || 17;
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" '
         + 'stroke-linecap="round" stroke-linejoin="round" width="' + n + '" height="' + n
         + '" aria-hidden="true">' + inner + '</svg>';
  }

  class ScreensRail {
    /**
     * @param {object} opts
     * @param {string} opts.udid
     * @param {HTMLElement} [opts.mount]  where the rail + card attach
     * @param {(entry:object) => void} [opts.onOpen]   show this screen's pane
     * @param {(entry:object) => void} [opts.onClose]  hide it again
     * @param {(msg:string) => void} [opts.log]
     */
    constructor({ udid, mount, onOpen, onClose, log }) {
      this.udid = udid;
      this.mount = mount || document.body;
      this.onOpen = onOpen || (() => {});
      this.onClose = onClose || (() => {});
      this.log = log || (() => {});
      this.screens = null;
      this.open = new Set();
      this.rail = null;
      this.card = null;
      this.buttons = new Map();
      this.bootPollTimer = null;
    }

    /**
     * Ask the host what is attached and draw the rail.
     *
     * A server that doesn't answer isn't a reason to hide the rail: the
     * entries still know how to explain themselves, and an empty right
     * edge would leave no way to find out that CarPlay exists at all.
     */
    async load() {
      this.screens = (await this.probe())
        ?? window.Baguette._CompanionScreens.from(null);
      this.render();
      this.restoreRemembered();
      if (!this.focusBound) {
        this.focusBound = true;
        this.bindFocusReprobe();
      }
    }

    /**
     * Re-probe when the page regains focus.
     *
     * Attaching a display happens in Simulator.app, not here, and there
     * is no event for it — so the moment you come back to the browser is
     * the moment to look again. Without this the rail is only ever as
     * fresh as the last page load or the last **Check again** press,
     * which is why an attached display "wasn't there" until a reload.
     *
     * Guarded on the answer actually differing, because `refresh()`
     * closes and reopens panes: acting on an unchanged probe would tear
     * down and rebuild live streams every single time you tab back.
     * Both events fire together in some browsers, hence the in-flight
     * latch rather than a timer.
     */
    bindFocusReprobe() {
      let inFlight = false;
      const look = async () => {
        if (inFlight || document.hidden) return;
        inFlight = true;
        try {
          const fresh = await this.probe();
          if (fresh && !fresh.sameAs(this.screens)) await this.refresh();
        } finally {
          inFlight = false;
        }
      };
      window.addEventListener('focus', look);
      document.addEventListener('visibilitychange', look);
    }

    /// Ask the host what is attached, without touching any state.
    async probe() {
      try {
        const res = await fetch(
          '/devices/' + encodeURIComponent(this.udid) + '/companion-screens.json',
          { cache: 'no-store' }
        );
        if (!res.ok) return null;
        return window.Baguette._CompanionScreens.from(await res.json());
      } catch (error) {
        this.log('companion screens unavailable: ' + ((error && error.message) || error));
        return null;
      }
    }

    /// Re-ask after the user has gone off and attached something. Panes
    /// that are open and still openable stay open; one whose screen went
    /// away closes rather than streaming a display that isn't there.
    async refresh() {
      const wasOpen = new Set(this.open);
      for (const id of wasOpen) this.closeScreen(id, { remember: false });
      await this.load();
      for (const id of wasOpen) {
        const entry = this.entry(id);
        if (entry && entry.canOpen) this.openScreen(id, { remember: false });
      }
    }

    /// Null until the first probe resolves — `mountScreensRail` kicks
    /// `load()` off without awaiting it, and a stream that faults in
    /// that window asks for its entry to draw the fault card. Throwing
    /// there would escape the socket callback and take the card with it,
    /// so an unprobed rail answers the same as an unknown id.
    entry(id) {
      if (!this.screens) return null;
      return this.screens.entries().find((e) => e.id === id) || null;
    }

    render() {
      if (this.rail) this.rail.remove();
      this.buttons.clear();

      const rail = document.createElement('aside');
      rail.className = 'screens-rail';
      rail.setAttribute('aria-label', 'Companion screens');

      const cap = document.createElement('div');
      cap.className = 'screens-rail-cap';
      cap.title = 'Companion screens';
      cap.innerHTML = svgWrap(RAIL_CAP, 16);
      rail.appendChild(cap);
      rail.appendChild(ScreensRail.divider());

      for (const entry of this.screens.entries()) {
        rail.appendChild(this.buildButton(entry));
      }

      rail.appendChild(ScreensRail.divider());
      const again = document.createElement('button');
      again.className = 'screens-rail-btn screens-rail-refresh';
      again.title = 'Check for screens again';
      again.setAttribute('aria-label', 'Check for companion screens again');
      again.innerHTML = svgWrap('<path d="M20 12a8 8 0 1 1-2.4-5.7"/><path d="M20 4v5h-5"/>', 16);
      again.addEventListener('click', () => this.refresh());
      rail.appendChild(again);

      this.mount.appendChild(rail);
      this.rail = rail;
    }

    static divider() {
      const divider = document.createElement('div');
      divider.className = 'screens-rail-divider';
      return divider;
    }

    /**
     * One slot per screen — present whether or not the screen is.
     *
     * A screen that isn't attached keeps its button and dims it. The
     * click then opens the card explaining how to attach one, which is
     * the only place that instruction can live: a rail that hid what you
     * don't have could never tell you how to get it.
     */
    buildButton(entry) {
      const button = document.createElement('button');
      button.className = 'screens-rail-btn';
      if (!entry.canOpen) button.classList.add('unavailable');
      button.innerHTML = svgWrap(GLYPHS[entry.id] || GLYPHS.external, 18);
      button.title = entry.canOpen
        ? entry.label
        : entry.label + ' — ' + entry.detail;
      button.setAttribute('aria-label', button.title);
      button.setAttribute('aria-pressed', 'false');
      button.addEventListener('click', () => this.clicked(entry));
      this.buttons.set(entry.id, button);
      return button;
    }

    clicked(entry) {
      if (!entry.canOpen) {
        this.showCard(entry);
        return;
      }
      this.closeCard();
      if (this.open.has(entry.id)) this.closeScreen(entry.id);
      else this.openScreen(entry.id);
    }

    // --- panes ---------------------------------------------------------

    openScreen(id, { remember = true } = {}) {
      const entry = this.entry(id);
      if (!entry || !entry.canOpen || this.open.has(id)) return;
      this.open.add(id);
      this.reflect(id);
      if (remember) this.remember();
      this.onOpen(entry);
    }

    closeScreen(id, { remember = true } = {}) {
      if (!this.open.has(id)) return;
      this.open.delete(id);
      this.reflect(id);
      if (remember) this.remember();
      const entry = this.entry(id);
      if (entry) this.onClose(entry);
    }

    reflect(id) {
      const button = this.buttons.get(id);
      if (!button) return;
      const open = this.open.has(id);
      button.classList.toggle('active', open);
      button.setAttribute('aria-pressed', open ? 'true' : 'false');
    }

    // --- remembered choice ---------------------------------------------
    //
    // Which panes you had open is a preference, not a session detail —
    // reloading the tab after an app rebuild shouldn't cost you the
    // layout you set up. A remembered screen that is no longer attached
    // is simply skipped; nothing here can resurrect a pane whose screen
    // has gone.

    remember() {
      try {
        localStorage.setItem(STORAGE_KEY, JSON.stringify([...this.open]));
      } catch (_) { /* private mode / quota — the rail still works */ }
    }

    restoreRemembered() {
      let stored = [];
      try {
        stored = JSON.parse(localStorage.getItem(STORAGE_KEY) || '[]');
      } catch (_) { stored = []; }
      if (!Array.isArray(stored)) return;
      for (const id of stored) this.openScreen(id, { remember: false });
    }

    // --- the "not attached" card ----------------------------------------

    showCard(entry) {
      this.closeCard();
      const card = document.createElement('div');
      card.className = 'screens-card';
      card.setAttribute('role', 'dialog');
      card.setAttribute('aria-label', entry.label);

      const head = document.createElement('div');
      head.className = 'screens-card-head';
      const title = document.createElement('span');
      title.className = 'screens-card-title';
      title.textContent = entry.label;
      const close = document.createElement('button');
      close.className = 'screens-card-close';
      close.setAttribute('aria-label', 'Close');
      close.textContent = '✕';
      close.addEventListener('click', () => this.closeCard());
      head.appendChild(title);
      head.appendChild(close);
      card.appendChild(head);

      const body = document.createElement('div');
      body.className = 'screens-card-body';
      const status = document.createElement('p');
      status.className = 'screens-card-status';
      status.textContent = entry.detail;
      body.appendChild(status);

      if (entry.status === 'needs-boot') {
        body.appendChild(this.bootControls(entry));
      } else if (entry.id === 'external') {
        body.appendChild(this.attachCarPlayControls(entry));
      } else {
        const list = document.createElement('ol');
        list.className = 'screens-steps';
        for (const step of entry.instructions) {
          const item = document.createElement('li');
          item.textContent = step;   // host copy, but never markup
          list.appendChild(item);
        }
        body.appendChild(list);

        const again = document.createElement('button');
        again.className = 'screens-card-btn';
        again.textContent = 'Check again';
        again.addEventListener('click', () => { this.closeCard(); this.refresh(); });
        body.appendChild(again);
      }

      card.appendChild(body);
      this.mount.appendChild(card);
      this.card = card;
      this.positionCard(card, this.buttons.get(entry.id));
    }

    /**
     * Attaching a CarPlay display, as a button plus the manual steps.
     *
     * The button is the better path: the menu attaches the display to
     * whichever simulator window is frontmost, and getting that wrong is
     * the usual reason doing it by hand appears to do nothing. baguette
     * raises this device's own window first.
     *
     * The steps stay underneath rather than being replaced by the
     * button, because driving another app's menus needs Automation
     * permission that may not be granted — and because the answer comes
     * back as a fresh probe, this can honestly report "still nothing to
     * stream" instead of claiming success.
     */
    attachCarPlayControls(entry) {
      const wrap = document.createElement('div');

      const button = document.createElement('button');
      button.className = 'screens-card-btn';
      button.textContent = 'Attach a CarPlay display';
      const note = document.createElement('p');
      note.className = 'screens-card-note';
      note.style.margin = '9px 0 0';

      button.addEventListener('click', async () => {
        button.disabled = true;
        button.textContent = 'Attaching…';
        note.textContent = 'Driving Simulator.app’s I/O menu — this takes a few seconds.';
        let payload = null;
        let failure = null;
        try {
          const res = await fetch(
            '/devices/' + encodeURIComponent(this.udid) + '/carplay-display',
            { method: 'POST' }
          );
          payload = await res.json();
          if (!res.ok) failure = (payload && payload.error) || ('HTTP ' + res.status);
        } catch (error) {
          failure = String((error && error.message) || error);
        }
        button.disabled = false;
        button.textContent = 'Try again';

        if (failure) { note.textContent = failure; return; }

        // The route answers with the resulting availability, so this
        // can tell "attached" from "clicked, and still nothing there".
        this.screens = window.Baguette._CompanionScreens.from(payload);
        const now = this.entry('external');
        if (now && now.canOpen) {
          this.closeCard();
          this.render();
          this.openScreen('external');
          return;
        }
        note.textContent =
          'The menu ran, but there is still no framebuffer to stream. '
          + 'Check that a CarPlay window opened in Simulator.app — if it did not, '
          + 'this runtime may not support one.';
      });

      wrap.appendChild(button);
      wrap.appendChild(note);

      const or = document.createElement('p');
      or.className = 'screens-card-note';
      or.style.margin = '11px 0 6px';
      // The button drives the CarPlay entry specifically, and that is
      // the entry some runtimes attach nothing for — so the manual path
      // is not just a fallback for missing permission, it is the one
      // that offers the resolutions that do work.
      or.textContent = 'Or by hand — and pick a plain resolution if CarPlay does nothing:';
      wrap.appendChild(or);

      const list = document.createElement('ol');
      list.className = 'screens-steps';
      for (const step of entry.instructions) {
        const item = document.createElement('li');
        item.textContent = step;
        list.appendChild(item);
      }
      wrap.appendChild(list);
      return wrap;
    }

    /// A paired watch that isn't running needs one button, not a page of
    /// prose — it is already the right device, it just isn't up yet.
    bootControls(entry) {
      const wrap = document.createElement('div');
      const note = document.createElement('p');
      note.className = 'screens-card-note';
      note.textContent =
        'This watch is paired with the phone but not running. Boot it to stream its screen.';
      wrap.appendChild(note);

      const button = document.createElement('button');
      button.className = 'screens-card-btn';
      button.textContent = 'Boot ' + entry.label;
      button.addEventListener('click', async () => {
        button.disabled = true;
        button.textContent = 'Booting…';
        try {
          await fetch('/devices/' + encodeURIComponent(entry.udid) + '/boot',
            { method: 'POST' });
        } catch (_) { /* the poll below is the real answer */ }
        this.pollForBoot(entry.udid, note, button);
      });
      wrap.appendChild(button);
      return wrap;
    }

    /// CoreSimulator answers the boot before the guest is up, so watch
    /// the device list rather than trusting the POST's return.
    pollForBoot(udid, note, button, deadline) {
      const until = deadline || (Date.now() + 120000);
      this.bootPollTimer = setTimeout(async () => {
        this.bootPollTimer = null;
        let booted = false;
        try {
          const res = await fetch('/simulators.json', { cache: 'no-store' });
          const json = await res.json();
          const all = (json.running || []).concat(json.available || []);
          const hit = all.find((d) => (d.id || d.udid) === udid);
          booted = !!hit && hit.state === 'Booted';
        } catch (_) { /* keep waiting */ }
        if (booted) {
          this.closeCard();
          await this.refresh();
          this.openScreen('watch');
          return;
        }
        if (Date.now() >= until) {
          note.textContent = 'Still not booted. Try again, or boot it from the simulator list.';
          button.disabled = false;
          button.textContent = 'Boot again';
          return;
        }
        this.pollForBoot(udid, note, button, until);
      }, 1000);
    }

    /// Anchored to the left of its button, then kept on screen — a rail
    /// slot near the bottom of a short window would hang off the edge.
    positionCard(card, button) {
      if (!button || !this.rail) return;
      const rail = this.rail.getBoundingClientRect();
      const anchor = button.getBoundingClientRect();
      card.style.right = (window.innerWidth - rail.left + 8) + 'px';
      const height = card.offsetHeight;
      const centred = anchor.top + anchor.height / 2 - height / 2;
      card.style.top = Math.max(12, Math.min(centred, window.innerHeight - height - 12)) + 'px';
    }

    closeCard() {
      if (this.bootPollTimer) { clearTimeout(this.bootPollTimer); this.bootPollTimer = null; }
      if (this.card) this.card.remove();
      this.card = null;
    }

    detach() {
      this.closeCard();
      if (this.rail) this.rail.remove();
      this.rail = null;
      this.buttons.clear();
    }
  }

  // No CSS here — the rail and its card are styled by the focus-mode
  // stylesheet in page/device-page.html, beside the plugin rail it shares a
  // shape with. See the note there.
  root.ScreensRail = ScreensRail;
})(window);
