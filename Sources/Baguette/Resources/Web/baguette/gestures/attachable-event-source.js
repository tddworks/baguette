// AttachableEventSource — the attach/detach lifecycle and listener
// bookkeeping every gesture source (mouse, touch, wheel, Safari
// GestureEvent) needs identically, plus the shared client-point mapping
// that honors 3D Interact mode's `mapClientPoint`. Concrete sources
// implement `_bind()`, called once `this._el` is set.

class AttachableEventSource {
  /**
   * @param {Screen} screen
   * @param {object} [opts]
   * @param {(clientX:number, clientY:number) => {x:number,y:number,
   *   xNorm:number,yNorm:number,inside:boolean}} [opts.mapClientPoint]
   */
  constructor(screen, { mapClientPoint } = {}) {
    this.screen = screen;
    this._mapClientPoint = mapClientPoint || null;
    this._handlers = [];
    this._el = null;
  }

  attach(el) {
    this._el = el;
    this._bind();
  }

  detach() {
    for (const [target, event, fn, opts] of this._handlers) {
      target.removeEventListener(event, fn, opts);
    }
    this._handlers = [];
    this._el = null;
  }

  _on(target, event, fn, opts) {
    target.addEventListener(event, fn, opts);
    this._handlers.push([target, event, fn, opts]);
  }

  /**
   * clientX/clientY → screen-space point, honoring `mapClientPoint`
   * when the bound element isn't a 1:1 crop of the screen (3D
   * Interact mode). Falls back to plain element-rect-relative math,
   * with `inside` always true, when no mapper is supplied.
   */
  _screenPoint(clientX, clientY) {
    if (this._mapClientPoint) return this._mapClientPoint(clientX, clientY);
    const r = this._el.getBoundingClientRect();
    const { width, height } = this.screen.size;
    const xNorm = r.width ? (clientX - r.left) / r.width : 0;
    const yNorm = r.height ? (clientY - r.top) / r.height : 0;
    return { x: xNorm * width, y: yNorm * height, xNorm, yNorm, inside: true };
  }

  /** Concrete sources wire their own listeners here via `this._on`. */
  _bind() {
    throw new Error('AttachableEventSource subclasses must implement _bind()');
  }
}

export { AttachableEventSource };

