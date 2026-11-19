// Keyboard — software keyboard input for devices that accept text.
// Forwards `keydown` events on the screen element to the server via
// the Transport. Focus-gated: only fires while the screen is the
// active element, so host browser shortcuts (Cmd+R / Cmd+T / …)
// keep working when the user is in the sidebar.
//
// The wire dialect carries `code` (W3C KeyboardEvent.code, e.g.
// `"KeyA"` / `"Digit1"` / `"Enter"`) and the four modifier flags;
// the backend (`KeyboardKey.from(wireCode:)`) resolves the HID
// usage. Frontend stays a dumb sender — no HID page/usage table.
//
// Whitelist below mirrors what `KeyboardKey.from(wireCode:)` accepts
// in `Sources/Device/Abilities/Key/Keyboard.swift`; keep the two
// in sync. Anything outside the set falls through to the host
// browser (so Cmd+R / DevTools shortcuts still work).
//
// Paste is the one carve-out: Cmd+V / Ctrl+V is NOT forwarded as a
// raw chord — the sim's pasteboard wouldn't hold the host's text, so
// the keystroke alone pastes nothing. Instead the chord is left to
// the browser so its native `paste` event fires; the document-level
// listener below reads the clipboard text off the event and sends a
// `{type:"paste"}` envelope (server: pbcopy, then Cmd+V sim-side).
//
// Copy is the mirror carve-out: Cmd+C / Ctrl+C is NOT forwarded as a
// raw chord either — instead it sends a `{type:"copy"}` envelope. The
// server presses Cmd+C sim-side (so the focused field copies its
// selection), then ferries the sim's pasteboard onto the host Mac's
// clipboard (pbsync <udid> host, images included). Perfect when the
// browser shares the Mac that runs baguette; for a remote browser it
// lands on the server's Mac.
(function (root) {
  'use strict';

  const FORWARDED = new Set([
    // Letters
    'KeyA','KeyB','KeyC','KeyD','KeyE','KeyF','KeyG','KeyH','KeyI','KeyJ',
    'KeyK','KeyL','KeyM','KeyN','KeyO','KeyP','KeyQ','KeyR','KeyS','KeyT',
    'KeyU','KeyV','KeyW','KeyX','KeyY','KeyZ',
    // Digits
    'Digit0','Digit1','Digit2','Digit3','Digit4','Digit5','Digit6','Digit7','Digit8','Digit9',
    // Numpad (physical numeric keypad — distinct HID keypad usages;
    // NumLock is omitted, iOS has no num-lock concept)
    'Numpad0','Numpad1','Numpad2','Numpad3','Numpad4','Numpad5','Numpad6','Numpad7','Numpad8','Numpad9',
    'NumpadDecimal','NumpadDivide','NumpadMultiply','NumpadSubtract','NumpadAdd','NumpadEnter','NumpadEqual',
    // Named specials
    'Enter','Escape','Backspace','Tab','Space',
    'ArrowUp','ArrowDown','ArrowLeft','ArrowRight',
    // Punctuation (US layout)
    'Minus','Equal','BracketLeft','BracketRight','Backslash',
    'Semicolon','Quote','Backquote','Comma','Period','Slash',
  ]);

  class Keyboard {
    /**
     * @param {object} _def      SimulatorDefinition.keyboard (reserved)
     * @param {Transport} transport
     */
    constructor(_def, transport) {
      this.transport = transport;
      this._el = null;
      this._onKeyDown = (ev) => this._handle(ev);
      this._onPaste = (ev) => this._handlePaste(ev);
    }

    /** Bind keydown to the screen element. Focus-gated. */
    attach(el) {
      if (!el) return;
      this._el = el;
      // Make the screen focusable + focus on click so keystrokes
      // routed through this element work without an explicit Tab.
      if (el.tabIndex < 0) el.tabIndex = 0;
      el.addEventListener('mousedown', () => el.focus());
      el.addEventListener('keydown', this._onKeyDown);
      // Document-level: Chrome/Firefox target the focused element,
      // Safari may target <body> when focus is a non-editable div —
      // document catches both. The focus gate in the handler keeps
      // sidebar pastes with the browser.
      document.addEventListener('paste', this._onPaste);
    }

    detach() {
      if (!this._el) return;
      this._el.removeEventListener('keydown', this._onKeyDown);
      document.removeEventListener('paste', this._onPaste);
      this._el = null;
    }

    // --- domain verbs ---

    /** Send a single key press. modifiers: array of
     *  `"shift" | "control" | "option" | "command"`. */
    key(code, modifiers) {
      const env = { type: 'key', code };
      if (modifiers && modifiers.length) env.modifiers = modifiers;
      this.transport._dispatch(env);
    }

    /** Send a string as a sequence of HID keystrokes (server-side). */
    type(text) {
      this.transport._dispatch({ type: 'type', text });
    }

    /** Paste text via the sim's pasteboard (server: pbcopy + Cmd+V).
     *  Any unicode — the path around `type`'s US-ASCII limit. */
    paste(text) {
      this.transport._dispatch({ type: 'paste', text });
    }

    /** Copy the focused field's selection out of the sim onto the
     *  host Mac's clipboard (server: Cmd+C sim-side, then pbsync
     *  <udid> host — images included). Mirror of `paste`; the server
     *  replies with a `copy_result` frame. */
    copy() {
      this.transport._dispatch({ type: 'copy' });
    }

    // --- internals ---

    _handle(ev) {
      // Focus gate — only forward when the screen owns focus.
      if (document.activeElement !== this._el) return;
      if (!FORWARDED.has(ev.code)) return;
      // Paste carve-out: don't preventDefault the paste chord, or
      // the browser never fires the `paste` event _handlePaste needs.
      if ((ev.metaKey || ev.ctrlKey) && ev.code === 'KeyV') return;
      // Copy carve-out: Cmd+C / Ctrl+C copies the sim's selection
      // and ferries it to the host (server: Cmd+C + pbsync) rather
      // than forwarding as a raw chord.
      if ((ev.metaKey || ev.ctrlKey) && ev.code === 'KeyC') {
        ev.preventDefault();
        this.copy();
        return;
      }
      ev.preventDefault();
      const modifiers = [];
      if (ev.shiftKey)   modifiers.push('shift');
      if (ev.ctrlKey)    modifiers.push('control');
      if (ev.altKey)     modifiers.push('option');
      if (ev.metaKey)    modifiers.push('command');
      this.key(ev.code, modifiers);
    }

    _handlePaste(ev) {
      // Same focus gate as keydown — a paste while the sidebar owns
      // focus belongs to the browser, not the sim.
      if (document.activeElement !== this._el) return;
      const text = ev.clipboardData && ev.clipboardData.getData('text/plain');
      if (!text) return;
      ev.preventDefault();
      this.paste(text);
    }
  }

  root.Baguette = root.Baguette || {};
  root.Baguette._Keyboard = Keyboard;
})(window);
