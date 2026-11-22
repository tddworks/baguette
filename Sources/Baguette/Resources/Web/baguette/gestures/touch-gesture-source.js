// TouchGestureSource — real multi-touch (iOS WebView). Single-finger
// touch (drag, edge gestures) streams touch1-*; a second finger abandons
// the touch path entirely and lets Safari's native gesturestart/change/
// end (SafariGestureEventSource) own the pinch — see the note below.
import { AttachableEventSource } from './attachable-event-source.js';
import { EdgeBands } from './edge-bands.js';

const MOVE_FLUSH_MS = 16; // ~60 fps coalescing window

class TouchGestureSource extends AttachableEventSource {
  /**
   * @param {Screen} screen
   * @param {object} [opts]
   * @param {PinchOverlay} [opts.overlay]
   * @param {() => string} [opts.getOrientation]
   * @param {(clientX:number, clientY:number) => object} [opts.mapClientPoint]
   */
  constructor(screen, { overlay, getOrientation, mapClientPoint } = {}) {
    super(screen, { mapClientPoint });
    this.overlay = overlay || null;
    this.getOrientation = getOrientation || (() => 'portrait');
  }

  _bind() {
    const opts = { passive: false };
    let state = null;
    let lastMs = 0;

    const relFingers = (touches) => {
      const r = this._el.getBoundingClientRect();
      const { width, height } = this.screen.size;
      return Array.from(touches).map((t) => ({
        // Chrome-pixel coords (visual rect → device-point scale)
        // so the wire envelope ships the same units as `tap`.
        x: ((t.clientX - r.left) / r.width) * width,
        y: ((t.clientY - r.top) / r.height) * height,
        // Pre-scaling raw pixels for the overlay HUD, which paints
        // host-local DOM dots in CSS pixels.
        vx: t.clientX - r.left, vy: t.clientY - r.top,
      }));
    };

    // iOS Safari fires BOTH `touchstart/move/end` AND `gesturestart/
    // change/end` for a 2-finger pinch. The legacy code only ever
    // attached MouseGestureSource (which listens to `gesture*`), so
    // pinch on iPhone was driven by Safari's `gesture*` stream
    // alone. If we ALSO emit `touch2-*` envelopes from this handler,
    // the simulator receives two interleaved touch2 streams and iOS
    // sees fingers teleporting between them → spinning.
    //
    // Resolution: when a second finger lands, abandon the touch
    // path entirely and let SafariGestureEventSource (gesturestart →
    // gesturechange → gestureend) own the pinch. Single-finger
    // touch (drag, edge gestures) stays here.
    this._on(this._el, 'touchstart', (e) => {
      e.preventDefault();
      const all = relFingers(e.touches);
      if (all.length >= 2) {
        // If we'd already shipped a touch1-down, lift it cleanly
        // before bowing out — otherwise the simulator holds a
        // phantom touch1 while `gesturestart` opens its own pinch.
        if (state && state.mode === 'single') {
          this.screen.touchUp([{ x: all[0].x, y: all[0].y }]);
        }
        state = { mode: 'multi-deferred' };  // gesture* will handle it
        // Paint the two real finger positions so the HUD lights up
        // the moment the second finger lands; touchmove keeps it
        // following (gesturechange's centroid-only positions are
        // too coarse to track each fingertip accurately).
        if (this.overlay) {
          this.overlay.setFingers(all.slice(0, 2).map((f) => ({ x: f.vx, y: f.vy })));
        }
        return;
      }
      if (all.length === 1) {
        // Edge-band detection — same shape as the mouse handler. In
        // 3D Interact mode a touch on the device bezel/body maps
        // outside the screen quad and starts nothing.
        const touch = e.touches[0];
        const point = this._screenPoint(touch.clientX, touch.clientY);
        if (point.inside) {
          // Tag the wire envelope with `edge:"bottom"` (or "top")
          // using the touch's REAL coords; no clamp. iOS treats the
          // flag as a swipe HINT — it commits to the home-indicator
          // recogniser when motion follows, otherwise the touch
          // lands as a normal tap at the real location and bottom-
          // band UI buttons still work.
          const startEdge = new EdgeBands(0.85, 0.15)
              .classify(point, this.getOrientation());

          if (startEdge) {
            state = { mode: 'edge-stream', edge: startEdge };
            this.screen.touchDown([point], { edge: startEdge });
          } else {
            state = { mode: 'single' };
            this.screen.touchDown([point]);
          }
        }
      }
      lastMs = 0;
    }, opts);

    this._on(this._el, 'touchmove', (e) => {
      e.preventDefault();
      if (!state) return;
      const all = relFingers(e.touches);

      // Multi-deferred: wire envelopes come from SafariGestureEventSource
      // (Safari's gesture* uses scale/rotation around a fixed
      // centroid and can't tell us each finger's real position).
      // But the overlay HUD wants to track the REAL fingers — so
      // keep painting from e.touches without dispatching wire.
      if (state.mode === 'multi-deferred') {
        if (this.overlay && all.length >= 2) {
          this.overlay.setFingers(all.slice(0, 2).map((f) => ({ x: f.vx, y: f.vy })));
        }
        return;
      }

      const now = performance.now();
      if (now - lastMs < MOVE_FLUSH_MS) return;
      lastMs = now;
      if (state.mode === 'edge-stream' && all.length === 1) {
        this.screen.touchMove(
            [this._screenPoint(e.touches[0].clientX, e.touches[0].clientY)],
            { edge: state.edge }
        );
      } else if (state.mode === 'single' && all.length === 1) {
        this.screen.touchMove(
            [this._screenPoint(e.touches[0].clientX, e.touches[0].clientY)]
        );
      } else if (state.mode === 'single' && all.length >= 2) {
        // Late-arriving second finger after a streaming single
        // touch had already started: close it cleanly and hand
        // off to SafariGestureEventSource. Overlay starts tracking
        // both fingers in the next touchmove.
        this.screen.touchUp([{ x: all[0].x, y: all[0].y }]);
        state = { mode: 'multi-deferred' };
        if (this.overlay) {
          this.overlay.setFingers(all.slice(0, 2).map((f) => ({ x: f.vx, y: f.vy })));
        }
      }
    }, opts);

    const endTouch = (e) => {
      e.preventDefault();
      if (!state) return;
      if (state.mode === 'multi-deferred') {
        // gesturestart/change/end owns this lifecycle.
        state = null;
        return;
      }
      const touch = e.changedTouches[0];
      const point = touch
        ? this._screenPoint(touch.clientX, touch.clientY)
        : { x: 0, y: 0 };
      if (state.mode === 'edge-stream') {
        this.screen.touchUp([point], { edge: state.edge });
      } else {
        this.screen.touchUp([point]);
      }
      state = null;
    };
    this._on(this._el, 'touchend', endTouch, opts);
    this._on(this._el, 'touchcancel', endTouch, opts);
  }
}

export { TouchGestureSource };

