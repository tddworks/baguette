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
// in `Sources/Baguette/Domain/Input/Keyboard.swift`; keep the two
// in sync. Anything outside the set falls through to the host
// browser (so Cmd+R / DevTools shortcuts still work).
(function (root) {
  'use strict';

  const FORWARDED = new Set([
    // Letters
    'KeyA','KeyB','KeyC','KeyD','KeyE','KeyF','KeyG','KeyH','KeyI','KeyJ',
    'KeyK','KeyL','KeyM','KeyN','KeyO','KeyP','KeyQ','KeyR','KeyS','KeyT',
    'KeyU','KeyV','KeyW','KeyX','KeyY','KeyZ',
    // Digits
    'Digit0','Digit1','Digit2','Digit3','Digit4','Digit5','Digit6','Digit7','Digit8','Digit9',
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
    }

    detach() {
      if (!this._el) return;
      this._el.removeEventListener('keydown', this._onKeyDown);
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

    // --- internals ---

    _handle(ev) {
      // Focus gate — only forward when the screen owns focus.
      if (document.activeElement !== this._el) return;
      if (!FORWARDED.has(ev.code)) return;
      ev.preventDefault();
      const modifiers = [];
      if (ev.shiftKey)   modifiers.push('shift');
      if (ev.ctrlKey)    modifiers.push('control');
      if (ev.altKey)     modifiers.push('option');
      if (ev.metaKey)    modifiers.push('command');
      this.key(ev.code, modifiers);
    }
  }

  root.Baguette = root.Baguette || {};
  root.Baguette._Keyboard = Keyboard;
})(window);
