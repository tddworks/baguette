// Screen — the device screen as a domain object. Owns the verbs
// (`tap`, `swipe`, …) the user invokes; emits them through the
// Transport. Knows nothing about wire formats, only about screen-
// space points in chrome pixels.
//
// PointerInterpreter (gestures/pointer-interpreter.js) hooks DOM
// events on the screen element and routes them back into THIS
// object's methods. Both directions cross the same domain
// boundary — the renderer / interpreter never serialises an
// envelope.
import { PinchOverlay } from '../gestures/pinch-overlay.js';
import { PointerInterpreter } from '../gestures/pointer-interpreter.js';
import { ScreenQuad } from '../gestures/screen-quad.js';

class Screen {
  /**
   * @param {object} def       SimulatorDefinition.screen
   * @param {Transport} transport
   * @param {object} [opts]
   * @param {() => string} [opts.getOrientation]
   * @param {(msg:string, isErr?:boolean)=>void} [opts.log]
   */
  constructor(def, transport, { getOrientation, log } = {}) {
    this.def = def;
    this.transport = transport;
    this.getOrientation = getOrientation || (() => 'portrait');
    this.log = log || (() => {});
    this.element = null;       // bound at mount time
    this.canvas = null;
    this._interpreter = null;
    this._overlay = null;
  }

  /** Called by Simulator once Bezel has built the DOM. */
  bindDOM({ screenArea, canvas }) {
    this.element = screenArea;
    this.canvas = canvas;
    let mapClientPoint;
    if (canvas && getComputedStyle(canvas).objectFit === 'contain') {
      mapClientPoint = (clientX, clientY) =>
        ScreenQuad.mapClientPointFromContain(
            canvas, clientX, clientY, this.size);
    }
    this.bindInteraction({ element: screenArea, overlayHost: screenArea, mapClientPoint });
  }

  /**
   * Bind the standard simulator interaction surface to any live view.
   * `mapClientPoint`, when supplied, overrides the default element-
   * rect-relative coordinate mapping — used by the 3D Interact mode,
   * where `element` is the whole canvas and the screen sits inside it
   * as a rotated, perspective-foreshortened quad.
   */
  bindInteraction({ element, overlayHost, mapClientPoint }) {
    this.unbindInteraction();
    this.element = element;
    this.transport.setScreenSize(this.def.rect.width, this.def.rect.height);
    this._overlay = new PinchOverlay(overlayHost || element);
    this._interpreter = new PointerInterpreter(this, {
      overlay: this._overlay,
      getOrientation: this.getOrientation,
      log: this.log,
      mapClientPoint,
    });
    this._interpreter.attach(element);
  }

  unbindInteraction() {
    if (this._interpreter) { this._interpreter.detach(); this._interpreter = null; }
    if (this._overlay) { this._overlay.detach(); this._overlay = null; }
  }

  detach() {
    this.unbindInteraction();
    this.element = null;
    this.canvas = null;
  }

  // --- domain verbs ---

  tap(point, opts) {
    this.transport.tap({
      x: point.x, y: point.y,
      duration: opts && opts.duration,
      edge: opts && opts.edge,
    });
  }

  swipe({ from, to, duration }) {
    this.transport.swipe({ from, to, duration });
  }

  /** The pointer over the screen with no button down, in screen points. */
  hover(point) { this.transport.hover(point); }

  touchDown(fingers, opts) { this.transport.touchDown(fingers, opts); }
  touchMove(fingers, opts) { this.transport.touchMove(fingers, opts); }
  touchUp  (fingers, opts) { this.transport.touchUp  (fingers, opts); }

  // --- helpers for the interpreter ---

  /** Width × height in chrome-pixel space. */
  get size() { return { width: this.def.rect.width, height: this.def.rect.height }; }
}

export { Screen };

