// HoverGestureSource — a mouse or trackpad moving over the screen with no
// button down, as `hover` (the device's pointer follows: hover effects,
// tooltips, an auto-hidden Dock). Only for a device with a pointer of its own
// (the `pointer` ability). At most one a frame, the newest — the server
// replaces a hover still waiting with a newer one too.
import { AttachableEventSource } from './attachable-event-source.js';

class HoverGestureSource extends AttachableEventSource {
  /**
   * @param {Screen} screen
   * @param {object} [opts]
   * @param {(fn: () => void) => void} [opts.schedule] once a frame; requestAnimationFrame
   */
  constructor(screen, { mapClientPoint, schedule } = {}) {
    super(screen, { mapClientPoint });
    this._schedule = schedule || ((fn) => window.requestAnimationFrame(fn));
    this._waiting = null;
  }

  /** A pointer event over the screen: a hover when a mouse moves with no button down. */
  moved(e) {
    if (e.pointerType !== 'mouse' || e.buttons !== 0) return;
    const first = this._waiting === null;
    const { x, y } = this._screenPoint(e.clientX, e.clientY);
    this._waiting = { x, y };
    if (first) this._schedule(() => this._send());
  }

  _send() {
    const at = this._waiting;
    this._waiting = null;
    if (at) this.screen.hover(at);
  }

  _bind() {
    this._on(this._el, 'pointermove', (e) => this.moved(e), { passive: true });
  }
}

export { HoverGestureSource };

