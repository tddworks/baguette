// KeyboardCapture — forwards Mac keyboard events into the simulator
// when the device's screen area has focus.
//
//   const cap = new KeyboardCapture({ target: surface.screenArea, simInput });
//   cap.start();   // bind listeners
//   cap.stop();    // unbind on teardown
//
// Capture is gated by focus: clicking the screen area (which already
// focuses it for tap dispatch) starts forwarding; clicking outside
// or pressing Esc twice releases. While the screen has focus we
// `preventDefault()` so host-browser shortcuts (Cmd+R, Cmd+T, …) go
// to iOS instead of triggering the host's reload / new-tab.
//
// Wire shape (handled by sim-input.js + sim-input-bridge.js):
//   { type: "key", code: "KeyA", modifiers: ["shift", "command"], duration: 0 }
//
// Frontend stays a dumb sender: it forwards `event.code` verbatim
// and the four modifier flags. The Swift side resolves the HID
// usage via `KeyboardKey.from(wireCode:)`. Unsupported codes get a
// gentle parse error from the backend; we don't filter here.
(function () {
  'use strict';

  // KeyboardEvent.code values we forward. Anything outside this set
  // is dropped so the host browser keeps its reload / devtools / etc
  // shortcuts. Keep this in sync with `KeyboardKey.from(wireCode:)`.
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

  class KeyboardCapture {
    // `simInput` may be an object with a `.key(code, modifiers)`
    // method, or a function returning one — the latter form lets the
    // host page swap simulators (or restart a session) without
    // re-mounting the capture.
    constructor({ target, simInput }) {
      this.target = target;
      this._simInputOrFactory = simInput;
      this._onKeyDown = this._onKeyDown.bind(this);
    }

    _resolveSimInput() {
      const v = this._simInputOrFactory;
      return (typeof v === 'function') ? v() : v;
    }

    start() {
      if (!this.target || this._bound) return;
      this.target.addEventListener('keydown', this._onKeyDown);
      this._bound = true;
    }

    stop() {
      if (!this._bound) return;
      this.target.removeEventListener('keydown', this._onKeyDown);
      this._bound = false;
    }

    isCapturing() {
      // Only forward when the target actually has focus. Otherwise
      // the user is interacting with the chrome / toolbar and host
      // shortcuts should keep working.
      return document.activeElement === this.target;
    }

    _onKeyDown(ev) {
      if (!this.isCapturing()) return;
      if (!FORWARDED.has(ev.code)) return;
      ev.preventDefault();
      ev.stopPropagation();
      const modifiers = [];
      if (ev.shiftKey) modifiers.push('shift');
      if (ev.ctrlKey)  modifiers.push('control');
      if (ev.altKey)   modifiers.push('option');
      if (ev.metaKey)  modifiers.push('command');
      const simInput = this._resolveSimInput();
      if (simInput) simInput.key(ev.code, modifiers);
    }
  }

  window.KeyboardCapture = KeyboardCapture;
})();
