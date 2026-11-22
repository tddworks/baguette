// MouseGestureSource — tap / drag / pinch / pan / edge on a plain mouse
// (matches Apple Simulator.app):
//   no modifier           → 1 finger: tap on release, drag-stream on
//                            motion, held touch-stream once the button
//                            sits still past LONG_PRESS_MS so iOS's
//                            long-press recognisers fire.
//   Option (alt) + drag   → 2-finger pinch around screen centre.
//   Option+Shift + drag   → 2-finger parallel pan around centre.
//
// Edge gestures: mousedown inside the visual edge band streams touch1-*
// with the `edge` flag set so iOS animates the home/app-switcher/
// notification-centre preview live during the drag.
//
// `onDragChange(active)` notifies OptionHoverPreview so it stops
// repainting the overlay out from under this source's own pinch/pan
// preview while a gesture is in progress — the one piece of state this
// source and OptionHoverPreview share, threaded through explicitly
// rather than reaching into each other.
import { AttachableEventSource } from './attachable-event-source.js';
import { EdgeBands } from './edge-bands.js';

const BASE_SPREAD_PT = 80;   // sim-pt for the pinch/pan modifier gesture
const DRAG_THRESHOLD_PX = 8; // mouse delta to promote pending→drag
// Mouse held still this long → promote to a held touch stream so
// iOS's long-press recognisers see a finger that stays down. Sits
// above a normal click (60–120 ms) and below UIKit's own 500 ms
// minimumPressDuration, which starts counting from OUR touch-down —
// so a context menu surfaces ~750 ms into the user's press.
const LONG_PRESS_MS = 250;
const MOVE_FLUSH_MS = 16;    // ~60 fps coalescing window

class MouseGestureSource extends AttachableEventSource {
  /**
   * @param {Screen} screen
   * @param {object} [opts]
   * @param {PinchOverlay} [opts.overlay]
   * @param {() => string} [opts.getOrientation]
   * @param {(msg:string, isErr?:boolean)=>void} [opts.log]
   * @param {(clientX:number, clientY:number) => object} [opts.mapClientPoint]
   * @param {(active:boolean) => void} [opts.onDragChange]
   */
  constructor(screen, {
    overlay, getOrientation, log, mapClientPoint, onDragChange,
  } = {}) {
    super(screen, { mapClientPoint });
    this.overlay = overlay || null;
    this.getOrientation = getOrientation || (() => 'portrait');
    this.log = log || (() => {});
    this._onDragChange = onDragChange || (() => {});
  }

  _screenCentrePt() {
    const { width, height } = this.screen.size;
    return { x: width / 2, y: height / 2 };
  }

  _ripple(clientX, clientY) {
    // `position: fixed` so the ripple lands where the cursor
    // actually is, regardless of any CSS rotation applied to
    // the screen element's ancestors.
    const r = document.createElement('div');
    r.style.cssText = `position:fixed;border:2px solid #6366f1;border-radius:50%;
      transform:translate(-50%,-50%);pointer-events:none;
      left:${clientX}px;top:${clientY}px;animation:baguetteRipple 0.5s ease-out forwards;z-index:10000;`;
    document.body.appendChild(r);
    setTimeout(() => r.remove(), 500);
  }

  _previewPinch(vx, vy, r) {
    if (!this.overlay) return;
    const pV = { x: r.width / 2, y: r.height / 2 };
    this.overlay.setFingers([
      { x: vx, y: vy },
      { x: 2 * pV.x - vx, y: 2 * pV.y - vy },
    ]);
  }

  _previewPan(r, shiftPxX, shiftPxY) {
    if (!this.overlay) return;
    const pV = { x: r.width / 2, y: r.height / 2 };
    const { width } = this.screen.size;
    const dxPx = (BASE_SPREAD_PT / width) * r.width;
    this.overlay.setFingers([
      { x: pV.x + dxPx + shiftPxX, y: pV.y + shiftPxY },
      { x: pV.x - dxPx + shiftPxX, y: pV.y + shiftPxY },
    ]);
  }

  _bind() {
    let state = null;
    let lastMoveMs = 0;

    // Disarm the pending press's long-press timer. Safe to call in
    // any state — only `pending` ever carries a timer.
    const cancelHold = () => {
      if (state && state.holdTimer) {
        clearTimeout(state.holdTimer);
        state.holdTimer = null;
      }
    };

    const modeOf = (e) =>
      (e.altKey && e.shiftKey) ? 'pan' :
      e.altKey                 ? 'pinch' :
                                 'tap-or-drag';

    // f1 / f2 are already in chrome-pixel space (the same units
    // the wire envelope carries). Don't normalise — `Screen.touch*`
    // → `Transport._touch` ships these verbatim, and the server's
    // `IndigoHIDInput.sendMouse` divides by size internally. Double-
    // normalising drives every touch envelope to ~(0,0).
    const sendTouch2 = (phase, f1, f2) => {
      const fs = [f1, f2];
      if (phase === 'down') this.screen.touchDown(fs);
      else if (phase === 'move') this.screen.touchMove(fs);
      else this.screen.touchUp(fs);
    };

    this._on(this._el, 'mousedown', (e) => {
      // In 3D Interact mode the bound element is the whole canvas, not
      // a 1:1 crop of the screen — a press on the device bezel/body
      // maps outside the screen quad and starts nothing.
      const point = this._screenPoint(e.clientX, e.clientY);
      if (!point.inside) return;
      const r = this._el.getBoundingClientRect();
      const vx = e.clientX - r.left, vy = e.clientY - r.top;
      const mode = modeOf(e);
      this._onDragChange(true);

      const startEdge = new EdgeBands(0.93, 0.07)
          .classify(point, this.getOrientation());

      if (mode === 'tap-or-drag' && startEdge) {
        state = { mode: 'edge-stream', edge: startEdge };
        this.screen.touchDown([point], { edge: startEdge });
        this.log('edge stream begin (' + this.getOrientation() + ', edge=' + startEdge + ')');
        return;
      }

      if (mode === 'pinch') {
        const pivot = this._screenCentrePt();
        const f1 = this._screenPoint(e.clientX, e.clientY);
        const f2 = { x: 2 * pivot.x - f1.x, y: 2 * pivot.y - f1.y };
        state = { mode, f1, f2 };
        sendTouch2('down', f1, f2);
        this._previewPinch(vx, vy, r);
        this.log('pinch begin');
      } else if (mode === 'pan') {
        const pivot = this._screenCentrePt();
        const f1 = { x: pivot.x + BASE_SPREAD_PT, y: pivot.y };
        const f2 = { x: pivot.x - BASE_SPREAD_PT, y: pivot.y };
        state = { mode, startVx: vx, startVy: vy, startW: r.width, startH: r.height,
                  pivotX: pivot.x, pivotY: pivot.y, f1, f2 };
        sendTouch2('down', f1, f2);
        this._previewPan(r, /* shiftPxX */ 0, /* shiftPxY */ 0);
        this.log('pan begin');
      } else {
        // Deferred: motion past DRAG_THRESHOLD_PX promotes to a drag
        // stream (see mousemove); stillness past LONG_PRESS_MS
        // promotes to a held touch stream (below); neither → a
        // one-shot tap on release.
        state = { mode: 'pending',
                  startVx: vx, startVy: vy, startW: r.width, startH: r.height,
                  startClientX: e.clientX, startClientY: e.clientY,
                  startedAt: Date.now(), holdTimer: null };

        // Long press. A held mouse button used to collapse into the
        // same 50 ms `tap` envelope as a click, so nothing that
        // needs a sustained touch — context menus, icon jiggle
        // mode, the magnifier loupe — could ever fire from the web
        // UI. Stream `touch1-down` now and let mouseup send
        // `touch1-up`, exactly like a real finger on the touch path.
        //
        // NOT a `tap` envelope with a long `duration`: that hold is
        // an `usleep` inside `IOHIDDigitizerDispatch.tap`, which
        // would block the server's MainActor for the whole press
        // (stalling every other gesture) and paint nothing until
        // release. Streaming shows iOS reacting live.
        //
        // Landing in `drag-stream` is deliberate — the finger is
        // already down, so sliding after the hold continues the same
        // touch. That's the sequence iOS wants for press-then-drag
        // (rearranging home-screen icons, dragging a list row).
        state.holdTimer = setTimeout(() => {
          // `detach()` nulls `_el` but can't reach this closure's
          // `state` — bail rather than strand a touch-down with no
          // matching up on a torn-down stream.
          if (!state || state.mode !== 'pending' || !this._el) return;
          const startPt = this._screenPoint(state.startClientX, state.startClientY);
          this._ripple(state.startClientX, state.startClientY);
          state = { mode: 'drag-stream', fromHold: true };
          this.screen.touchDown([startPt]);
          lastMoveMs = 0;
          this.log('long press begin');
        }, LONG_PRESS_MS);
      }
    });

    this._on(this._el, 'mousemove', (e) => {
      if (!state) return;
      const r = this._el.getBoundingClientRect();
      const vx = e.clientX - r.left, vy = e.clientY - r.top;

      if (state.mode === 'edge-stream') {
        this.screen.touchMove([this._screenPoint(e.clientX, e.clientY)], { edge: state.edge });
        return;
      }

      if (state.mode === 'pinch') {
        const pivot = this._screenCentrePt();
        state.f1 = this._screenPoint(e.clientX, e.clientY);
        state.f2 = { x: 2 * pivot.x - state.f1.x, y: 2 * pivot.y - state.f1.y };
        sendTouch2('move', state.f1, state.f2);
        this._previewPinch(vx, vy, r);
        return;
      }

      if (state.mode === 'pan') {
        const { width, height } = this.screen.size;
        const shiftX = ((vx - state.startVx) / state.startW) * width;
        const shiftY = ((vy - state.startVy) / state.startH) * height;
        state.f1 = { x: state.pivotX + BASE_SPREAD_PT + shiftX, y: state.pivotY + shiftY };
        state.f2 = { x: state.pivotX - BASE_SPREAD_PT + shiftX, y: state.pivotY + shiftY };
        sendTouch2('move', state.f1, state.f2);
        this._previewPan(r, vx - state.startVx, vy - state.startVy);
        return;
      }

      // Promote pending → drag-stream once the cursor moves past
      // the tap threshold. Stream a SINGLE finger (`touch1-*`): the
      // digitizer recipe (IOHIDDigitizerDispatch) threads one
      // continuous touch with a sticky identifier, which is what
      // drives single-finger recognisers — SwiftUI `DragGesture`,
      // `ScrollView` pan, table/list scroll. The old two-coincident-
      // finger hack (`touch2-*`) routed through the legacy mouse path
      // and landed as a degenerate two-finger gesture that those
      // single-touch recognisers ignore. Pinch / pan stay 2-finger
      // and are gated behind the Alt / Shift modifiers above.
      if (state.mode === 'pending') {
        if (Math.hypot(vx - state.startVx, vy - state.startVy) < DRAG_THRESHOLD_PX) return;
        cancelHold();
        const start = this._screenPoint(
            state.startVx + (e.clientX - vx),
            state.startVy + (e.clientY - vy)
        );
        state = { mode: 'drag-stream' };
        this.screen.touchDown([start]);
        lastMoveMs = 0;
      }

      if (state.mode === 'drag-stream') {
        const now = performance.now();
        if (now - lastMoveMs < MOVE_FLUSH_MS) return;
        lastMoveMs = now;
        this.screen.touchMove([this._screenPoint(e.clientX, e.clientY)]);
      }
    });

    const end = (e) => {
      if (!state) return;
      cancelHold();

      if (state.mode === 'edge-stream') {
        this.screen.touchUp([this._screenPoint(e.clientX, e.clientY)], { edge: state.edge });
        this.log('edge stream end');
      } else if (state.mode === 'pinch' || state.mode === 'pan') {
        sendTouch2('up', state.f1, state.f2);
        if (this.overlay) this.overlay.clear();
        this.log(`${state.mode} end`);
      } else if (state.mode === 'drag-stream') {
        this.screen.touchUp([this._screenPoint(e.clientX, e.clientY)]);
        this.log(state.fromHold ? 'long press end' : 'drag end');
      } else if (state.mode === 'pending') {
        // Never promoted past tap threshold → one-shot tap.
        const r0 = this._el.getBoundingClientRect();
        const pt = this._screenPoint(state.startVx + r0.left, state.startVy + r0.top);
        this.screen.tap(pt);
        this._ripple(state.startClientX, state.startClientY);
        this.log('tap');
      }
      state = null;
      this._onDragChange(false);
    };

    this._on(this._el, 'mouseup', end);
    this._on(this._el, 'mouseleave', end);
  }
}

// Inject the tap/long-press ripple keyframes once.
if (typeof document !== 'undefined' && !document.getElementById('baguetteRippleStyle')) {
  const s = document.createElement('style');
  s.id = 'baguetteRippleStyle';
  s.textContent = '@keyframes baguetteRipple { 0% { opacity:1;width:10px;height:10px;border-width:2px } 50% { opacity:0.7;width:30px;height:30px;border-width:2px } 100% { opacity:0;width:50px;height:50px;border-width:1px } }';
  document.head.appendChild(s);
}

export { MouseGestureSource };

