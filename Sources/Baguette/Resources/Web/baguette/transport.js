// Transport — the ONE module that knows the wire format. Every other
// part of the SDK calls Transport methods in domain terms ("send a
// tap"); only this file knows that translates to a JSON envelope
// with a `type` field. The SDK boundary makes the wire dialect a
// hidden implementation detail of the SDK — bumping the protocol is
// a one-file change.
//
// Constructed with a `send(payload)` callback the consumer page
// supplies (today: StreamSession.send, the same WebSocket that
// carries frames). Keeping socket lifecycle outside the SDK means
// the SDK can plug into any transport — page-owned WS, asc-cli
// plugin's adapter, future stdin pipe — without changes.
(function (root) {
  'use strict';

  class Transport {
    /**
     * @param {object} opts
     * @param {(payload:object)=>void} opts.send  upstream sink (e.g. WS)
     * @param {(msg:string, isErr?:boolean)=>void} [opts.log]
     */
    constructor({ send, log }) {
      this._send = send;
      this._log = log || (() => {});
    }

    /** Update the screen size carried on every gesture envelope. */
    setScreenSize(width, height) {
      this._width = width;
      this._height = height;
    }

    // --- Domain verbs the SDK parts call ---
    // Envelope shape lives in GestureEnvelope (gestures/gesture-envelope.js)
    // — this class owns dispatch (send + error logging + screen-size state).

    tap(args) {
      this._dispatch(root.Baguette._GestureEnvelope.tap(args, this._size()));
    }

    swipe(args) {
      this._dispatch(root.Baguette._GestureEnvelope.swipe(args, this._size()));
    }

    hover(point) {
      this._dispatch(root.Baguette._GestureEnvelope.hover(point, this._size()));
    }

    touchDown(fingers, opts)  { this._touch('down', fingers, opts); }
    touchMove(fingers, opts)  { this._touch('move', fingers, opts); }
    touchUp  (fingers, opts)  { this._touch('up',   fingers, opts); }

    /** Hardware-button press — the SDK's Button.press wraps this. */
    button(envelope, { hold = 0 } = {}) {
      const out = { ...envelope };
      if (hold > 0) out.duration = hold;
      this._dispatch(out);
    }

    // --- internals ---

    _touch(phase, fingers, opts) {
      const envelope = root.Baguette._GestureEnvelope.touch(phase, fingers, opts, this._size());
      if (envelope) this._dispatch(envelope);
    }

    _size() {
      return { width: this._width || 0, height: this._height || 0 };
    }

    _dispatch(envelope) {
      try { this._send(envelope); }
      catch (e) { this._log(`${envelope.type}: ${e.message}`, true); }
    }
  }

  root.Baguette = root.Baguette || {};
  root.Baguette._Transport = Transport;
})(window);
