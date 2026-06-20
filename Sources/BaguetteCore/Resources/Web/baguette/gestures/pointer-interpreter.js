// PointerInterpreter — DOM events on the screen element →
// Screen domain methods. Knows mouse and touch event shapes and
// when a press is a tap vs a drag vs a pinch vs an edge-stream;
// does NOT know wire formats. Always calls Screen verbs
// (`tap`, `swipe`, `touchDown`, `touchMove`, `touchUp`).
//
// Modifier-key multi-touch (matches Apple Simulator.app):
//   no modifier           → 1 finger: tap on release, drag-stream
//                            on motion (synthesised as 2 coincident
//                            fingers because iOS 26.4 misroutes
//                            single-point streaming).
//   Option (alt) + drag   → 2-finger pinch around screen centre.
//   Option+Shift + drag   → 2-finger parallel pan around centre.
//   Wheel                 → 2-finger pan with idle-close.
//   Ctrl+Wheel            → 2-finger pinch with idle-close.
//   Safari gesturestart*  → 2-finger pinch with rotation.
//
// Edge gestures: mousedown inside the visual edge band streams
// `touch1-*` with the `edge` flag set so iOS animates the home /
// app-switcher / notification-centre preview live during the drag.
// Edge zones are computed against the current device orientation
// — portrait-upside-down's home-indicator hot zone is visual-left
// (xNorm ≤ 0.07) instead of visual-bottom (yNorm ≥ 0.93).
//
// Option-hover preview: holding Option (with cursor over the
// screen) shows two virtual finger dots WITHOUT clicking, matching
// Apple Simulator.app. Pinch preview = cursor + mirror-through-
// centre; pan preview = parallel finger pair at centre.
(function (root) {
  'use strict';

  const BASE_SPREAD_PT = 80;            // sim-pt for pinch/pan modifier
  const DRAG_THRESHOLD_PX = 8;          // mouse delta to promote pending→drag
  const EDGE_BAND_NORM = 0.93;          // mouse: bottom edge hot zone
  const TOP_BAND_NORM  = 0.07;          // mouse: top edge hot zone
  // Touch on iPhone Safari reports `clientY` as the centroid of the
  // contact ellipse, ~10–20 px above the user's visual fingertip.
  // A wider band catches what the user perceives as a bottom swipe.
  // Importantly we do NOT clamp the coord — same as mouse, the wire
  // envelope carries the real `y` and `edge:"bottom"`. iOS uses the
  // flag only for swipe disambiguation; a tap (no motion) at
  // yNorm=0.90 still lands on whatever app button is there.
  const TOUCH_EDGE_BAND_NORM = 0.85;
  const TOUCH_TOP_BAND_NORM  = 0.15;
  const WHEEL_IDLE_MS  = 120;           // wheel idle → close 2-finger
  const MOVE_FLUSH_MS  = 16;            // ~60 fps coalescing window

  class PointerInterpreter {
    /**
     * @param {Screen} screen   the SDK Screen part to dispatch into
     * @param {object} [opts]
     * @param {PinchOverlay} [opts.overlay]  visual HUD
     * @param {() => string} [opts.getOrientation]  device orientation
     * @param {(msg:string, isErr?:boolean)=>void} [opts.log]
     */
    constructor(screen, { overlay, getOrientation, log } = {}) {
      this.screen = screen;
      this.overlay = overlay || null;
      this.getOrientation = getOrientation || (() => 'portrait');
      this.log = log || (() => {});
      this._handlers = [];
      this._dragActive = false;
      this._optionHeld = false;
      this._shiftHeld  = false;
      this._cursorVx = 0; this._cursorVy = 0;
      this._cursorInside = false;
    }

    attach(el) {
      this._el = el;
      this._mountMouse();
      this._mountWheel();
      this._mountGestureEvent();
      this._mountOptionHoverPreview();
      this._mountTouch();
    }

    detach() {
      for (const [t, ev, fn, opts] of this._handlers) t.removeEventListener(ev, fn, opts);
      this._handlers = [];
      this._el = null;
    }

    _on(target, event, fn, opts) {
      target.addEventListener(event, fn, opts);
      this._handlers.push([target, event, fn, opts]);
    }

    /** view → chrome-pixel point in screen space. */
    _pointInScreen(e) {
      const r = this._el.getBoundingClientRect();
      const { width, height } = this.screen.size;
      return {
        x: ((e.clientX - r.left) / r.width)  * width,
        y: ((e.clientY - r.top)  / r.height) * height,
      };
    }

    _normInScreen(e) {
      const r = this._el.getBoundingClientRect();
      return {
        x: (e.clientX - r.left) / r.width,
        y: (e.clientY - r.top)  / r.height,
      };
    }

    _ptToNorm(pt) {
      const { width, height } = this.screen.size;
      return { x: pt.x / width, y: pt.y / height };
    }

    _screenCentrePt() {
      const { width, height } = this.screen.size;
      return { x: width / 2, y: height / 2 };
    }

    // --- Mouse: tap / drag / pinch / pan / edge ----------------------

    _mountMouse() {
      let state = null;
      let lastMoveMs = 0;

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
        const r = this._el.getBoundingClientRect();
        const vx = e.clientX - r.left, vy = e.clientY - r.top;
        const mode = modeOf(e);
        this._dragActive = true;

        // Edge-stream detection — orientation-aware.
        const xNorm = r.width  ? (vx / r.width)  : 0;
        const yNorm = r.height ? (vy / r.height) : 0;
        const ori = this.getOrientation();
        const inBottomBand = ori === 'portrait-upside-down'
          ? xNorm <= (1 - EDGE_BAND_NORM)
          : yNorm >= EDGE_BAND_NORM;
        const inTopBand = ori === 'portrait-upside-down'
          ? xNorm >= EDGE_BAND_NORM
          : yNorm <= TOP_BAND_NORM;
        const startEdge = inBottomBand ? 'bottom' : (inTopBand ? 'top' : null);

        if (mode === 'tap-or-drag' && startEdge) {
          state = { mode: 'edge-stream', edge: startEdge };
          this.screen.touchDown([this._pointInScreen(e)], { edge: startEdge });
          this.log('edge stream begin (' + ori + ', edge=' + startEdge + ')');
          return;
        }

        if (mode === 'pinch') {
          const pivot = this._screenCentrePt();
          const f1 = this._pointInScreen(e);
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
          // Deferred: decide tap vs drag on first movement past threshold.
          state = { mode: 'pending',
                    startVx: vx, startVy: vy, startW: r.width, startH: r.height,
                    startClientX: e.clientX, startClientY: e.clientY,
                    startedAt: Date.now() };
        }
      });

      this._on(this._el, 'mousemove', (e) => {
        if (!state) return;
        const r = this._el.getBoundingClientRect();
        const vx = e.clientX - r.left, vy = e.clientY - r.top;

        if (state.mode === 'edge-stream') {
          this.screen.touchMove([this._pointInScreen(e)], { edge: state.edge });
          return;
        }

        if (state.mode === 'pinch') {
          const pivot = this._screenCentrePt();
          state.f1 = this._pointInScreen(e);
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
          const start = this._pointInScreen({
            clientX: state.startVx + (e.clientX - vx),
            clientY: state.startVy + (e.clientY - vy),
          });
          state = { mode: 'drag-stream' };
          this.screen.touchDown([start]);
          lastMoveMs = 0;
        }

        if (state.mode === 'drag-stream') {
          const now = performance.now();
          if (now - lastMoveMs < MOVE_FLUSH_MS) return;
          lastMoveMs = now;
          this.screen.touchMove([this._pointInScreen(e)]);
        }
      });

      const end = (e) => {
        if (!state) return;
        const r = this._el.getBoundingClientRect();
        const vx = e.clientX - r.left, vy = e.clientY - r.top;

        if (state.mode === 'edge-stream') {
          this.screen.touchUp([this._pointInScreen(e)], { edge: state.edge });
          this.log('edge stream end');
        } else if (state.mode === 'pinch' || state.mode === 'pan') {
          sendTouch2('up', state.f1, state.f2);
          if (this.overlay) this.overlay.clear();
          this.log(`${state.mode} end`);
        } else if (state.mode === 'drag-stream') {
          this.screen.touchUp([this._pointInScreen(e)]);
          this.log('drag end');
        } else if (state.mode === 'pending') {
          // Never promoted past tap threshold → one-shot tap.
          const r0 = this._el.getBoundingClientRect();
          const pt = this._pointInScreen({
            clientX: state.startVx + r0.left,
            clientY: state.startVy + r0.top,
          });
          this.screen.tap(pt);
          this._ripple(state.startClientX, state.startClientY);
          this.log('tap');
        }
        state = null;
        this._dragActive = false;
        this._updatePreview();
      };

      this._on(this._el, 'mouseup', end);
      this._on(this._el, 'mouseleave', end);
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

    // --- Wheel → 2-finger pinch/pan with idle close ------------------

    _mountWheel() {
      let state = null;

      const close = () => {
        if (!state) return;
        this.screen.touchUp([state.f1, state.f2]);
        if (this.overlay) this.overlay.clear();
        state = null;
      };

      this._on(this._el, 'wheel', (e) => {
        e.preventDefault();
        const { width, height } = this.screen.size;
        if (!width || !height) return;
        const r = this._el.getBoundingClientRect();
        const vx = e.clientX - r.left, vy = e.clientY - r.top;
        const centre = {
          x: (vx / r.width)  * width,
          y: (vy / r.height) * height,
        };
        const wantKind = e.ctrlKey ? 'pinch' : 'pan';

        if (!state || state.kind !== wantKind) {
          if (state) close();
          state = {
            kind: wantKind, centre,
            viewCx: vx, viewCy: vy,
            viewR: (BASE_SPREAD_PT / width) * r.width,
            f1: { x: centre.x + BASE_SPREAD_PT, y: centre.y },
            f2: { x: centre.x - BASE_SPREAD_PT, y: centre.y },
            scale: 1, idleTimer: null,
          };
          this.screen.touchDown([state.f1, state.f2]);
        }

        if (state.kind === 'pinch') {
          state.scale = Math.max(0.25, Math.min(6, state.scale * Math.exp(-e.deltaY / 200)));
          const rr = BASE_SPREAD_PT * state.scale;
          state.f1 = { x: centre.x + rr, y: centre.y };
          state.f2 = { x: centre.x - rr, y: centre.y };
        } else {
          const shiftX = (-e.deltaX / r.width)  * width;
          const shiftY = (-e.deltaY / r.height) * height;
          state.f1.x += shiftX; state.f1.y += shiftY;
          state.f2.x += shiftX; state.f2.y += shiftY;
        }

        this.screen.touchMove([state.f1, state.f2]);

        if (this.overlay) {
          if (state.kind === 'pinch') {
            const vr = state.viewR * state.scale;
            this.overlay.setFingers([
              { x: state.viewCx + vr, y: state.viewCy },
              { x: state.viewCx - vr, y: state.viewCy },
            ]);
          } else {
            const dxPx = (state.f1.x - centre.x) / width  * r.width;
            const dyPx = (state.f1.y - centre.y) / height * r.height;
            this.overlay.setFingers([
              { x: vx + dxPx, y: vy + dyPx },
              { x: vx - dxPx, y: vy - dyPx },
            ]);
          }
        }

        clearTimeout(state.idleTimer);
        state.idleTimer = setTimeout(close, WHEEL_IDLE_MS);
      }, { passive: false });
    }

    // --- Safari GestureEvent → 2-finger pinch with rotation ----------

    _mountGestureEvent() {
      let state = null;

      const fingersFor = (scale, rotRad, centreDev, baseDev) => {
        const rr = baseDev * scale;
        const dx = Math.cos(rotRad) * rr;
        const dy = Math.sin(rotRad) * rr;
        // Chrome-pixel coords — `centreDev` is already chrome-pixel
        // and the wire envelope expects chrome-pixel. Don't divide.
        return [
          { x: centreDev.x + dx, y: centreDev.y + dy },
          { x: centreDev.x - dx, y: centreDev.y - dy },
        ];
      };

      this._on(this._el, 'gesturestart', (e) => {
        e.preventDefault();
        const { width, height } = this.screen.size;
        if (!width || !height) return;
        const r = this._el.getBoundingClientRect();
        const vx = e.clientX - r.left, vy = e.clientY - r.top;
        const centreDev = {
          x: (vx / r.width)  * width,
          y: (vy / r.height) * height,
        };
        state = {
          centreVx: vx, centreVy: vy,
          centreDev,
          viewR: (BASE_SPREAD_PT / width) * r.width,
          lastMs: 0,
        };
        const fingers = fingersFor(1, 0, centreDev, BASE_SPREAD_PT);
        this.screen.touchDown(fingers);
        if (this.overlay) {
          this.overlay.setFingers([
            { x: vx + state.viewR, y: vy },
            { x: vx - state.viewR, y: vy },
          ]);
        }
      });

      // Recompute the centroid from the event's clientX/Y on each
      // change. Apple's `GestureEvent.clientX/Y` carries the CURRENT
      // midpoint between the two fingers (not the gesturestart
      // anchor), so updating `state.centreDev` here lets a 2-finger
      // pan in Apple Maps / Photos translate the synthesized fingers
      // — without this, the pair stayed mirrored around the original
      // landing centroid and the user couldn't shift the map.
      const updateCentre = (e) => {
        const r = this._el.getBoundingClientRect();
        const { width, height } = this.screen.size;
        const vx = e.clientX - r.left, vy = e.clientY - r.top;
        state.centreVx = vx;
        state.centreVy = vy;
        state.centreDev = {
          x: (vx / r.width)  * width,
          y: (vy / r.height) * height,
        };
        state.viewR = (BASE_SPREAD_PT / width) * r.width;
      };

      this._on(this._el, 'gesturechange', (e) => {
        e.preventDefault();
        if (!state) return;
        updateCentre(e);
        const scale = e.scale || 1;
        const rotRad = ((e.rotation || 0) * Math.PI) / 180;
        if (this.overlay) {
          const vdx = Math.cos(rotRad) * state.viewR * scale;
          const vdy = Math.sin(rotRad) * state.viewR * scale;
          this.overlay.setFingers([
            { x: state.centreVx + vdx, y: state.centreVy + vdy },
            { x: state.centreVx - vdx, y: state.centreVy - vdy },
          ]);
        }
        const now = performance.now();
        if (now - state.lastMs < MOVE_FLUSH_MS) return;
        state.lastMs = now;
        this.screen.touchMove(fingersFor(scale, rotRad, state.centreDev, BASE_SPREAD_PT));
      });

      this._on(this._el, 'gestureend', (e) => {
        e.preventDefault();
        if (!state) return;
        updateCentre(e);
        const scale = e.scale || 1;
        const rotRad = ((e.rotation || 0) * Math.PI) / 180;
        this.screen.touchUp(fingersFor(scale, rotRad, state.centreDev, BASE_SPREAD_PT));
        if (this.overlay) this.overlay.clear();
        state = null;
      });
    }

    // --- Option-hover preview ----------------------------------------

    _updatePreview() {
      if (!this.overlay) return;
      if (this._dragActive) return;
      if (!this._optionHeld || !this._cursorInside) { this.overlay.clear(); return; }
      const r = this._el.getBoundingClientRect();
      const { width } = this.screen.size;
      if (!width) return;
      const pV = { x: r.width / 2, y: r.height / 2 };
      if (this._shiftHeld) {
        const dxPx = (BASE_SPREAD_PT / width) * r.width;
        this.overlay.setFingers([
          { x: pV.x + dxPx, y: pV.y },
          { x: pV.x - dxPx, y: pV.y },
        ]);
      } else {
        this.overlay.setFingers([
          { x: this._cursorVx, y: this._cursorVy },
          { x: 2 * pV.x - this._cursorVx, y: 2 * pV.y - this._cursorVy },
        ]);
      }
    }

    _mountOptionHoverPreview() {
      const updateCursor = (e) => {
        const r = this._el.getBoundingClientRect();
        this._cursorVx = e.clientX - r.left;
        this._cursorVy = e.clientY - r.top;
      };
      this._on(this._el, 'mousemove', (e) => {
        updateCursor(e); this._cursorInside = true;
        if (!this._dragActive) this._updatePreview();
      });
      this._on(this._el, 'mouseenter', (e) => {
        updateCursor(e); this._cursorInside = true;
        this._updatePreview();
      });
      this._on(this._el, 'mouseleave', () => {
        this._cursorInside = false; this._updatePreview();
      });
      this._on(window, 'keydown', (e) => {
        let changed = false;
        if (e.key === 'Alt' || e.key === 'AltGraph' || e.key === 'Option') {
          if (!this._optionHeld) { this._optionHeld = true; changed = true; }
        }
        if (e.key === 'Shift') {
          if (!this._shiftHeld) { this._shiftHeld = true; changed = true; }
        }
        if (changed) this._updatePreview();
      });
      this._on(window, 'keyup', (e) => {
        let changed = false;
        if (e.key === 'Alt' || e.key === 'AltGraph' || e.key === 'Option') {
          if (this._optionHeld) { this._optionHeld = false; changed = true; }
        }
        if (e.key === 'Shift') {
          if (this._shiftHeld) { this._shiftHeld = false; changed = true; }
        }
        if (changed) this._updatePreview();
      });
      this._on(window, 'blur', () => {
        if (this._optionHeld || this._shiftHeld) {
          this._optionHeld = false; this._shiftHeld = false;
          this._updatePreview();
        }
      });
    }

    // --- Touch (iOS WebView, real multi-touch) -----------------------

    _mountTouch() {
      const opts = { passive: false };
      let state = null;
      let lastMs = 0;

      const relFingers = (touches) => {
        const r = this._el.getBoundingClientRect();
        const { width, height } = this.screen.size;
        return Array.from(touches).map(t => ({
          // Chrome-pixel coords (visual rect → device-point scale)
          // so the wire envelope ships the same units as `tap`.
          x: ((t.clientX - r.left) / r.width)  * width,
          y: ((t.clientY - r.top)  / r.height) * height,
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
      // path entirely and let `_mountGestureEvent` (gesturestart →
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
            this.overlay.setFingers(all.slice(0, 2).map(f => ({ x: f.vx, y: f.vy })));
          }
          return;
        }
        if (all.length === 1) {
          // Edge-band detection — same shape as the mouse handler.
          // Tag the wire envelope with `edge:"bottom"` (or "top")
          // using the touch's REAL coords; no clamp. iOS treats the
          // flag as a swipe HINT — it commits to the home-indicator
          // recogniser when motion follows, otherwise the touch
          // lands as a normal tap at the real location and bottom-
          // band UI buttons still work.
          const r = this._el.getBoundingClientRect();
          const xNorm = r.width  ? (all[0].vx / r.width)  : 0;
          const yNorm = r.height ? (all[0].vy / r.height) : 0;
          const ori = this.getOrientation();
          const inBottomBand = ori === 'portrait-upside-down'
            ? xNorm <= (1 - TOUCH_EDGE_BAND_NORM)
            : yNorm >= TOUCH_EDGE_BAND_NORM;
          const inTopBand = ori === 'portrait-upside-down'
            ? xNorm >= TOUCH_EDGE_BAND_NORM
            : yNorm <= TOUCH_TOP_BAND_NORM;
          const startEdge = inBottomBand ? 'bottom' : (inTopBand ? 'top' : null);

          if (startEdge) {
            state = { mode: 'edge-stream', edge: startEdge };
            this.screen.touchDown(
              [{ x: all[0].x, y: all[0].y }],
              { edge: startEdge }
            );
          } else {
            state = { mode: 'single' };
            this.screen.touchDown([{ x: all[0].x, y: all[0].y }]);
          }
        }
        lastMs = 0;
      }, opts);

      this._on(this._el, 'touchmove', (e) => {
        e.preventDefault();
        if (!state) return;
        const all = relFingers(e.touches);

        // Multi-deferred: wire envelopes come from `_mountGestureEvent`
        // (Safari's gesture* uses scale/rotation around a fixed
        // centroid and can't tell us each finger's real position).
        // But the overlay HUD wants to track the REAL fingers — so
        // keep painting from e.touches without dispatching wire.
        if (state.mode === 'multi-deferred') {
          if (this.overlay && all.length >= 2) {
            this.overlay.setFingers(all.slice(0, 2).map(f => ({ x: f.vx, y: f.vy })));
          }
          return;
        }

        const now = performance.now();
        if (now - lastMs < MOVE_FLUSH_MS) return;
        lastMs = now;
        if (state.mode === 'edge-stream' && all.length === 1) {
          this.screen.touchMove(
            [{ x: all[0].x, y: all[0].y }],
            { edge: state.edge }
          );
        } else if (state.mode === 'single' && all.length === 1) {
          this.screen.touchMove([{ x: all[0].x, y: all[0].y }]);
        } else if (state.mode === 'single' && all.length >= 2) {
          // Late-arriving second finger after a streaming single
          // touch had already started: close it cleanly and hand
          // off to `_mountGestureEvent`. Overlay starts tracking
          // both fingers in the next touchmove.
          this.screen.touchUp([{ x: all[0].x, y: all[0].y }]);
          state = { mode: 'multi-deferred' };
          if (this.overlay) {
            this.overlay.setFingers(all.slice(0, 2).map(f => ({ x: f.vx, y: f.vy })));
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
        const ended = relFingers(e.changedTouches);
        const f = ended[0] || { x: 0, y: 0 };
        if (state.mode === 'edge-stream') {
          this.screen.touchUp([{ x: f.x, y: f.y }], { edge: state.edge });
        } else {
          this.screen.touchUp([{ x: f.x, y: f.y }]);
        }
        state = null;
      };
      this._on(this._el, 'touchend',    endTouch, opts);
      this._on(this._el, 'touchcancel', endTouch, opts);
    }
  }

  // Inject the ripple keyframes once.
  if (typeof document !== 'undefined' && !document.getElementById('baguetteRippleStyle')) {
    const s = document.createElement('style');
    s.id = 'baguetteRippleStyle';
    s.textContent = '@keyframes baguetteRipple { 0% { opacity:1;width:10px;height:10px;border-width:2px } 50% { opacity:0.7;width:30px;height:30px;border-width:2px } 100% { opacity:0;width:50px;height:50px;border-width:1px } }';
    document.head.appendChild(s);
  }

  root.Baguette = root.Baguette || {};
  root.Baguette._PointerInterpreter = PointerInterpreter;
})(window);
