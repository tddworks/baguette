// ASC Pro — Simulator Input Module (v2 event schema)
//
// Shared by:
//   • plugin/ui/sim-stream.js        (Mac browser, uses MouseGestureSource)
//   • MobileStreamPage (iOS WebView)  (uses TouchGestureSource)
//
// Architecture:
//   SimInput               — public API. Knows v2 wire format + HTTP
//                            transport. Callers speak in normalized coords
//                            (0–1) plus a configured screen size.
//   MouseGestureSource     — Mac trackpad: mouse, wheel, Safari gesture*.
//   TouchGestureSource     — iOS touch: touchstart/move/end/cancel.
//   PinchOverlay           — visual HUD; both sources push finger positions.
//
// SRP: one class per responsibility. Sources don't format JSON; SimInput
// doesn't know about DOM events; the overlay only draws.
// OCP: add a new source by dropping in a class that calls SimInput —
// nothing in SimInput or the existing sources needs to change.

(function(global) {
  'use strict';

  // --- Public API ---

  class SimInput {
    /**
     * @param {object} opts
     * @param {string} opts.apiBase  e.g. "http://host:3100/api/sim"
     * @param {string} opts.udid
     * @param {(msg:string, isErr?:boolean)=>void} [opts.log]
     */
    constructor({ apiBase, udid, log, transport }) {
      this.apiBase = apiBase;
      this.transport = transport;
      this.udid = udid;
      this.log = log || (() => {});
      this.width = 0;
      this.height = 0;
    }

    setScreenSize(width, height) {
      this.width = width;
      this.height = height;
    }

    // --- Kinds ---

    tap(xNorm, yNorm, duration) {
      return this._post({ kind: 'tap', x: xNorm, y: yNorm, duration }, { size: true });
    }

    swipe(x1, y1, x2, y2, duration) {
      return this._post({ kind: 'swipe', x1, y1, x2, y2, duration }, { size: true });
    }

    // Touch streams (touchDown / touchMove / touchUp) are serialized through
    // one promise chain so the server sees them in the order the user made
    // them — even though each request is a separate HTTP POST, completion
    // order can otherwise drift across HTTP/1.1 sockets and the simulator
    // ends up shaking on pinches/rotates. `touchMove` additionally coalesces
    // (latest-wins): while a move is in flight, new moves replace the
    // pending fingers instead of queueing, so we never lag behind the
    // cursor by more than ~one RTT.

    touchDown(fingers) {
      return this._chainTouch(() =>
        this._post({ kind: 'touchDown', fingers }, { size: true }));
    }

    touchMove(fingers) {
      if (this._pendingMove) {
        this._pendingMove.fingers = fingers;
        return this._touchChain;
      }
      const slot = { fingers };
      this._pendingMove = slot;
      return this._chainTouch(() => {
        this._pendingMove = null;
        return this._post({ kind: 'touchMove', fingers: slot.fingers }, { size: true });
      });
    }

    touchUp(fingers) {
      // Flush any pending move first so up never overtakes a coalesced move.
      if (this._pendingMove) {
        const slot = this._pendingMove;
        this._pendingMove = null;
        this._chainTouch(() =>
          this._post({ kind: 'touchMove', fingers: slot.fingers }, { size: true }));
      }
      return this._chainTouch(() =>
        this._post({ kind: 'touchUp', fingers }, { size: true }));
    }

    _chainTouch(thunk) {
      this._touchChain = (this._touchChain || Promise.resolve())
        .then(thunk)
        .catch(e => this.log(`touch: ${e.message}`, true));
      return this._touchChain;
    }

    scroll(deltaX, deltaY) {
      return this._post({ kind: 'scroll', deltaX, deltaY });
    }

    button(name, duration) {
      const body = { kind: 'button', button: name };
      if (typeof duration === 'number' && duration > 0) body.duration = duration;
      return this._post(body);
    }

    type(text) {
      return this._post({ kind: 'type', text });
    }

    key(keycode) {
      return this._post({ kind: 'key', keycode });
    }

    // --- Transport ---

    async _post(body, { size = false } = {}) {
      const payload = { ...body, udid: this.udid };
      if (size) { payload.width = this.width; payload.height = this.height; }
      // Prefer an injected transport when given (e.g. WebSocket on
      // baguette serve). Falls back to legacy POST /event so the
      // asc-cli plugin keeps working unchanged.
      if (this.transport) {
        try { this.transport(payload); }
        catch (e) { this.log(`${body.kind}: ${e.message}`, true); }
        return;
      }
      try {
        const res = await fetch(`${this.apiBase}/event`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload),
        });
        if (!res.ok) this.log(`${body.kind} HTTP ${res.status}`, true);
      } catch (e) {
        this.log(`${body.kind}: ${e.message}`, true);
      }
    }
  }

  // --- PinchOverlay ---
  //
  // Absolute-positioned dots inside a host element. Non-interactive.

  class PinchOverlay {
    /** @param {HTMLElement} host */
    constructor(host) {
      this.host = host;
      this.container = document.createElement('div');
      this.container.style.cssText = 'position:absolute;inset:0;pointer-events:none;z-index:9;';
      host.appendChild(this.container);
    }

    /** @param {{x:number,y:number}[]} points  pixels, host-local */
    setFingers(points) {
      const kids = this.container.children;
      while (kids.length < points.length) this.container.appendChild(PinchOverlay._dot());
      while (kids.length > points.length) this.container.removeChild(kids[0]);
      for (let i = 0; i < points.length; i++) {
        kids[i].style.left = points[i].x + 'px';
        kids[i].style.top  = points[i].y + 'px';
      }
    }

    clear() { this.container.innerHTML = ''; }

    static _dot() {
      const d = document.createElement('div');
      d.style.cssText = [
        'position:absolute', 'width:36px', 'height:36px',
        'margin-left:-18px', 'margin-top:-18px', 'border-radius:50%',
        'background:rgba(99,102,241,0.35)',
        'border:2px solid rgba(99,102,241,0.9)',
        'box-shadow:0 0 12px rgba(99,102,241,0.5)',
      ].join(';');
      return d;
    }
  }

  // --- MouseGestureSource ---
  //
  // Mac trackpad / mouse. Translates:
  //   mouse down → up       → tap (if short) or swipe (if moved)
  //   wheel                 → scroll (per-event, no debounce)
  //   ctrl+wheel            → pinch stream (touchDown / move / up)
  //   Safari gesture*       → pinch stream with rotation

  class MouseGestureSource {
    /**
     * @param {object} opts
     * @param {HTMLElement} opts.el          hit target (screen area)
     * @param {SimInput}    opts.input
     * @param {PinchOverlay} [opts.overlay]
     * @param {(msg:string)=>void} [opts.log]
     */
    constructor({ el, input, overlay, log }) {
      this.el = el;
      this.input = input;
      this.overlay = overlay;
      this.log = log || (() => {});
      this._handlers = [];
      // Shared with _attachOptionHoverPreview so the preview pauses while a
      // real gesture is streaming.
      this._dragActive = false;
      this._optionHeld = false;
      this._shiftHeld = false;
      this._cursorVx = 0;
      this._cursorVy = 0;
      this._cursorInside = false;
    }

    attach() {
      this._attachMouseInput();
      this._attachWheelAsTwoDrag();
      this._attachPinchGesture();
      this._attachOptionHoverPreview();
    }

    detach() {
      for (const [target, event, fn, opts] of this._handlers) {
        target.removeEventListener(event, fn, opts);
      }
      this._handlers = [];
    }

    _on(target, event, fn, opts) {
      target.addEventListener(event, fn, opts);
      this._handlers.push([target, event, fn, opts]);
    }

    // --- Mouse input (Simulator.app-style modifier-key multi-touch) ---
    //
    //   no modifier             → 1 finger: tap on release, swipe on drag
    //                              (one-shot, host-tap / host-swipe)
    //   Option (alt) + drag     → 2-finger pinch stream. Fingers mirror
    //                              around mousedown center; spread = signed
    //                              radial distance (right of start = zoom in,
    //                              left = zoom out). host-touch2-*.
    //   Option + Shift + drag   → 2-finger parallel pan stream. Both fingers
    //                              translate together with the cursor.
    //                              host-touch2-*.
    //
    // Routing only through the proven-working one-shot (host-tap/host-swipe)
    // and 2-finger stream (host-touch2) paths — never host-touch1 or
    // host-scroll, both broken on iOS 26.4.

    _attachMouseInput() {
      const BASE = 80;  // sim-pt initial spread for pinch/pan modifiers
      let state = null;
      // state shapes:
      //   { mode: 'tap-or-swipe', startVx, startVy, startW, startH, startedAt, dragging }
      //   { mode: 'pinch'|'pan', startVx, startVy, startW, startH, centerDev, baseSpread, f1, f2 }

      const modeOf = (e) =>
        (e.altKey && e.shiftKey) ? 'pan' :
        e.altKey                 ? 'pinch' :
                                   'tap-or-swipe';

      const viewToDev = (vx, vy, vw, vh) => ({
        x: (vx / vw) * this.input.width,
        y: (vy / vh) * this.input.height,
      });

      const send2 = (phase, f1, f2) => {
        const fs = [
          { x: f1.x / this.input.width, y: f1.y / this.input.height },
          { x: f2.x / this.input.width, y: f2.y / this.input.height },
        ];
        if (phase === 'down') this.input.touchDown(fs);
        else if (phase === 'move') this.input.touchMove(fs);
        else this.input.touchUp(fs);
      };

      // Simulator.app's pinch / pan pivot is the sim SCREEN CENTER, not the
      // mousedown position. finger1 tracks the cursor; finger2 is reflected
      // through the center.
      const pivotDev = () => ({
        x: this.input.width / 2,
        y: this.input.height / 2,
      });
      const pivotView = (r) => ({ x: r.width / 2, y: r.height / 2 });

      const DRAG_THRESHOLD_PX = 8;
      let lastMoveMs = 0;

      this._on(this.el, 'mousedown', (e) => {
        const r = this.el.getBoundingClientRect();
        const vx = e.clientX - r.left, vy = e.clientY - r.top;
        const mode = modeOf(e);
        this._dragActive = true;

        if (mode === 'pinch') {
          const pDev = pivotDev();
          const f1 = viewToDev(vx, vy, r.width, r.height);
          const f2 = { x: 2 * pDev.x - f1.x, y: 2 * pDev.y - f1.y };
          state = { mode, startVx: vx, startVy: vy, startW: r.width, startH: r.height, f1, f2 };
          send2('down', f1, f2);
          const pV = pivotView(r);
          this.overlay && this.overlay.setFingers([
            { x: vx, y: vy },
            { x: 2 * pV.x - vx, y: 2 * pV.y - vy },
          ]);
          this.log('pinch begin');
        } else if (mode === 'pan') {
          const pDev = pivotDev();
          const f1 = { x: pDev.x + BASE, y: pDev.y };
          const f2 = { x: pDev.x - BASE, y: pDev.y };
          state = { mode, startVx: vx, startVy: vy, startW: r.width, startH: r.height,
                    baseSpread: BASE, pivotDevX: pDev.x, pivotDevY: pDev.y, f1, f2 };
          send2('down', f1, f2);
          const pV = pivotView(r);
          const dxPx = (BASE / this.input.width) * r.width;
          this.overlay && this.overlay.setFingers([
            { x: pV.x + dxPx, y: pV.y },
            { x: pV.x - dxPx, y: pV.y },
          ]);
          this.log('pan begin');
        } else {
          // Deferred: decide tap vs drag on first movement past the threshold.
          state = { mode: 'pending',
                    startVx: vx, startVy: vy, startW: r.width, startH: r.height,
                    startedAt: Date.now() };
        }
      });

      this._on(this.el, 'mousemove', (e) => {
        if (!state) return;
        const r = this.el.getBoundingClientRect();
        const vx = e.clientX - r.left, vy = e.clientY - r.top;

        if (state.mode === 'pinch') {
          const pDev = pivotDev();
          state.f1 = viewToDev(vx, vy, r.width, r.height);
          state.f2 = { x: 2 * pDev.x - state.f1.x, y: 2 * pDev.y - state.f1.y };
          send2('move', state.f1, state.f2);
          const pV = pivotView(r);
          this.overlay && this.overlay.setFingers([
            { x: vx, y: vy },
            { x: 2 * pV.x - vx, y: 2 * pV.y - vy },
          ]);
          return;
        }
        if (state.mode === 'pan') {
          const shiftX = ((vx - state.startVx) / state.startW) * this.input.width;
          const shiftY = ((vy - state.startVy) / state.startH) * this.input.height;
          state.f1 = { x: state.pivotDevX + state.baseSpread + shiftX, y: state.pivotDevY + shiftY };
          state.f2 = { x: state.pivotDevX - state.baseSpread + shiftX, y: state.pivotDevY + shiftY };
          send2('move', state.f1, state.f2);
          const pV = pivotView(r);
          const dxPx = (state.baseSpread / this.input.width) * r.width;
          const shiftPxX = vx - state.startVx, shiftPxY = vy - state.startVy;
          this.overlay && this.overlay.setFingers([
            { x: pV.x + dxPx + shiftPxX, y: pV.y + shiftPxY },
            { x: pV.x - dxPx + shiftPxX, y: pV.y + shiftPxY },
          ]);
          return;
        }

        // Promote `pending` → `drag-stream` once the cursor leaves the tap
        // threshold. Stream via 2 coincident fingers (host-touch2-*) so the
        // drag lands on UIKit's pan recognizer in real time — single-point
        // IndigoHIDMessageForMouseNSEvent streaming doesn't work on iOS 26.4.
        if (state.mode === 'pending') {
          if (Math.hypot(vx - state.startVx, vy - state.startVy) < DRAG_THRESHOLD_PX) return;
          const start = viewToDev(state.startVx, state.startVy, r.width, r.height);
          state = { mode: 'drag-stream', startW: r.width, startH: r.height,
                    f1: { ...start }, f2: { ...start } };
          send2('down', state.f1, state.f2);
          lastMoveMs = 0;
        }

        if (state.mode === 'drag-stream') {
          const now = performance.now();
          if (now - lastMoveMs < 16) return;
          lastMoveMs = now;
          const cur = viewToDev(vx, vy, r.width, r.height);
          state.f1 = cur;
          state.f2 = { ...cur };
          send2('move', state.f1, state.f2);
        }
      });

      const end = (e) => {
        if (!state) return;
        const r = this.el.getBoundingClientRect();
        const vx = e.clientX - r.left, vy = e.clientY - r.top;

        if (state.mode === 'pinch' || state.mode === 'pan') {
          send2('up', state.f1, state.f2);
          if (this.overlay) this.overlay.clear();
          this.log(`${state.mode} end`);
        } else if (state.mode === 'drag-stream') {
          const cur = viewToDev(vx, vy, r.width, r.height);
          send2('up', cur, { ...cur });
          this.log('drag end');
        } else {
          // Never promoted past the tap threshold → one-shot tap.
          this.input.tap(state.startVx / state.startW, state.startVy / state.startH);
          this._ripple(state.startVx, state.startVy);
          this.log('tap');
        }
        state = null;
        this._dragActive = false;
        // If Option is still held when the gesture ends, bring the hover
        // preview back so the user can chain another pinch/pan.
        this._updatePreview();
      };

      this._on(this.el, 'mouseup', end);
      this._on(this.el, 'mouseleave', end);
    }

    _ripple(x, y) {
      const r = document.createElement('div');
      r.style.cssText = `position:absolute;border:2px solid #6366f1;border-radius:50%;
        transform:translate(-50%,-50%);pointer-events:none;
        left:${x}px;top:${y}px;animation:simRipple 0.5s ease-out forwards;z-index:10;`;
      this.el.appendChild(r);
      setTimeout(() => r.remove(), 500);
    }

    // --- Wheel → synthesized 2-finger stream ---
    //
    // `scroll` kind crashes backboardd on iOS 26.4, so wheel is synthesized
    // as a 2-finger gesture via host-touch2-*:
    //   plain wheel → 2-finger parallel pan (both fingers translate together)
    //   ctrl+wheel  → 2-finger pinch (spread/shrink around cursor, Chromium)
    // Both auto-close after 120ms of idle.

    _attachWheelAsTwoDrag() {
      const BASE = 80;
      let state = null;

      const close = () => {
        if (!state) return;
        this.input.touchUp([
          { x: state.f1.x / this.input.width, y: state.f1.y / this.input.height },
          { x: state.f2.x / this.input.width, y: state.f2.y / this.input.height },
        ]);
        if (this.overlay) this.overlay.clear();
        state = null;
      };

      this._on(this.el, 'wheel', (e) => {
        e.preventDefault();
        if (!this.input.width || !this.input.height) return;
        const r = this.el.getBoundingClientRect();
        const vx = e.clientX - r.left, vy = e.clientY - r.top;
        const centerDev = {
          x: (vx / r.width) * this.input.width,
          y: (vy / r.height) * this.input.height,
        };
        const wantKind = e.ctrlKey ? 'pinch' : 'pan';

        if (!state || state.kind !== wantKind) {
          if (state) close();
          state = {
            kind: wantKind, centerDev,
            viewCenterX: vx, viewCenterY: vy,
            viewR: (BASE / this.input.width) * r.width,
            f1: { x: centerDev.x + BASE, y: centerDev.y },
            f2: { x: centerDev.x - BASE, y: centerDev.y },
            scale: 1, idleTimer: null,
          };
          this.input.touchDown([
            { x: state.f1.x / this.input.width, y: state.f1.y / this.input.height },
            { x: state.f2.x / this.input.width, y: state.f2.y / this.input.height },
          ]);
        }

        if (state.kind === 'pinch') {
          state.scale = Math.max(0.25, Math.min(6, state.scale * Math.exp(-e.deltaY / 200)));
          const rr = BASE * state.scale;
          state.f1 = { x: centerDev.x + rr, y: centerDev.y };
          state.f2 = { x: centerDev.x - rr, y: centerDev.y };
        } else {
          const shiftX = (-e.deltaX / r.width) * this.input.width;
          const shiftY = (-e.deltaY / r.height) * this.input.height;
          state.f1.x += shiftX; state.f1.y += shiftY;
          state.f2.x += shiftX; state.f2.y += shiftY;
        }

        this.input.touchMove([
          { x: state.f1.x / this.input.width, y: state.f1.y / this.input.height },
          { x: state.f2.x / this.input.width, y: state.f2.y / this.input.height },
        ]);

        if (this.overlay) {
          if (state.kind === 'pinch') {
            const vr = state.viewR * state.scale;
            this.overlay.setFingers([
              { x: state.viewCenterX + vr, y: state.viewCenterY },
              { x: state.viewCenterX - vr, y: state.viewCenterY },
            ]);
          } else {
            const dxPx = (state.f1.x - centerDev.x) / this.input.width * r.width;
            const dyPx = (state.f1.y - centerDev.y) / this.input.height * r.height;
            this.overlay.setFingers([
              { x: vx + dxPx, y: vy + dyPx },
              { x: vx - dxPx, y: vy - dyPx },
            ]);
          }
        }

        clearTimeout(state.idleTimer);
        state.idleTimer = setTimeout(close, 120);
      }, { passive: false });
    }

    // --- Safari GestureEvent → pinch stream (touchDown / move / up) ---

    _attachPinchGesture() {
      // Sim-space radius of a "scale=1" two-finger spread.
      const BASE_SPREAD_DEV = 80;
      const MIN_FLUSH_MS = 16;

      let state = null;  // { centerViewX/Y, centerDev, screenW, screenH, viewRadiusPx, lastMs, lastFingers }

      const viewToDev = (vx, vy, vw, vh) => ({
        x: (vx / vw) * this.input.width,
        y: (vy / vh) * this.input.height,
      });
      const fingersFor = (scale, rotRad, centerDev, baseDev) => {
        const r = baseDev * scale;
        const dx = Math.cos(rotRad) * r;
        const dy = Math.sin(rotRad) * r;
        return [
          { x: (centerDev.x + dx) / this.input.width,
            y: (centerDev.y + dy) / this.input.height },
          { x: (centerDev.x - dx) / this.input.width,
            y: (centerDev.y - dy) / this.input.height },
        ];
      };

      this._on(this.el, 'gesturestart', (e) => {
        e.preventDefault();
        if (!this.input.width || !this.input.height) return;
        const r = this.el.getBoundingClientRect();
        const vx = e.clientX - r.left, vy = e.clientY - r.top;
        const centerDev = viewToDev(vx, vy, r.width, r.height);
        state = {
          centerViewX: vx, centerViewY: vy,
          centerDev,
          viewRadiusPx: (BASE_SPREAD_DEV / this.input.width) * r.width,
          lastMs: 0,
        };
        const fingers = fingersFor(1, 0, centerDev, BASE_SPREAD_DEV);
        state.lastFingers = fingers;
        this.input.touchDown(fingers);
        if (this.overlay) this.overlay.setFingers([
          { x: vx + state.viewRadiusPx, y: vy },
          { x: vx - state.viewRadiusPx, y: vy },
        ]);
        this.log('pinch begin');
      });

      this._on(this.el, 'gesturechange', (e) => {
        e.preventDefault();
        if (!state) return;
        const scale = e.scale || 1;
        const rotRad = ((e.rotation || 0) * Math.PI) / 180;

        if (this.overlay) {
          const vdx = Math.cos(rotRad) * state.viewRadiusPx * scale;
          const vdy = Math.sin(rotRad) * state.viewRadiusPx * scale;
          this.overlay.setFingers([
            { x: state.centerViewX + vdx, y: state.centerViewY + vdy },
            { x: state.centerViewX - vdx, y: state.centerViewY - vdy },
          ]);
        }

        const now = performance.now();
        if (now - state.lastMs < MIN_FLUSH_MS) return;
        const fingers = fingersFor(scale, rotRad, state.centerDev, BASE_SPREAD_DEV);
        state.lastFingers = fingers;
        state.lastMs = now;
        this.input.touchMove(fingers);
      });

      this._on(this.el, 'gestureend', (e) => {
        e.preventDefault();
        if (!state) return;
        const scale = e.scale || 1;
        const rotRad = ((e.rotation || 0) * Math.PI) / 180;
        const fingers = fingersFor(scale, rotRad, state.centerDev, BASE_SPREAD_DEV);
        this.input.touchUp(fingers);
        if (this.overlay) this.overlay.clear();
        state = null;
        this.log(`pinch end scale=${scale.toFixed(2)} rot=${(rotRad * 180 / Math.PI).toFixed(1)}°`);
      });
    }

    // --- Option-hover preview ---
    //
    // Matches Apple Simulator.app: holding Option (with cursor over the
    // device screen) shows two virtual finger dots without needing to
    // click. Moving the mouse repositions them live. Option alone → pinch
    // preview (cursor + mirror through screen center). Option+Shift →
    // pan preview (parallel finger pair around center).
    //
    // The preview is suppressed while a real gesture is streaming and
    // re-applied when the gesture ends or the cursor re-enters.

    _updatePreview() {
      if (!this.overlay) return;
      if (this._dragActive) return;
      if (!this._optionHeld || !this._cursorInside) {
        this.overlay.clear();
        return;
      }
      if (!this.input.width || !this.input.height) return;
      const r = this.el.getBoundingClientRect();
      const pV = { x: r.width / 2, y: r.height / 2 };
      if (this._shiftHeld) {
        const BASE = 80;
        const dxPx = (BASE / this.input.width) * r.width;
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

    _attachOptionHoverPreview() {
      const updateCursor = (e) => {
        const r = this.el.getBoundingClientRect();
        this._cursorVx = e.clientX - r.left;
        this._cursorVy = e.clientY - r.top;
      };

      this._on(this.el, 'mousemove', (e) => {
        updateCursor(e);
        this._cursorInside = true;
        if (!this._dragActive) this._updatePreview();
      });
      this._on(this.el, 'mouseenter', (e) => {
        updateCursor(e);
        this._cursorInside = true;
        this._updatePreview();
      });
      this._on(this.el, 'mouseleave', () => {
        this._cursorInside = false;
        this._updatePreview();
      });

      // Key listeners on the window so Option state tracks even when focus
      // isn't on the device area.
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
          this._optionHeld = false;
          this._shiftHeld = false;
          this._updatePreview();
        }
      });
    }
  }

  // --- TouchGestureSource ---
  //
  // iOS native touch (real multi-touch). Translates:
  //   1 finger tap          → tap
  //   1 finger drag         → swipe on release
  //   2+ fingers            → touchDown / touchMove / touchUp (exactly 2 forwarded)

  class TouchGestureSource {
    constructor({ el, input, overlay, log }) {
      this.el = el;
      this.input = input;
      this.overlay = overlay;
      this.log = log || (() => {});
      this._handlers = [];
      this._state = null;
    }

    attach() {
      const opts = { passive: false };
      this._on(this.el, 'touchstart', (e) => this._onStart(e), opts);
      this._on(this.el, 'touchmove',  (e) => this._onMove(e),  opts);
      this._on(this.el, 'touchend',   (e) => this._onEnd(e),   opts);
      this._on(this.el, 'touchcancel',(e) => this._onEnd(e),   opts);
    }

    detach() {
      for (const [target, event, fn, opts] of this._handlers) {
        target.removeEventListener(event, fn, opts);
      }
      this._handlers = [];
    }

    _on(target, event, fn, opts) {
      target.addEventListener(event, fn, opts);
      this._handlers.push([target, event, fn, opts]);
    }

    _relFingers(touches) {
      const r = this.el.getBoundingClientRect();
      return Array.from(touches).map(t => ({
        vx: t.clientX - r.left, vy: t.clientY - r.top, vw: r.width, vh: r.height,
      }));
    }

    _norm(f) { return { x: f.vx / f.vw, y: f.vy / f.vh }; }

    // State: { mode: 'single' | 'multi', lastSendMs: number }
    // Single-finger drag streams just like pinch — one continuous touchDown
    // → many touchMoves → touchUp. UIKit classifies minimal motion as a tap
    // on its own, so no special tap branch at this layer.

    _onStart(e) {
      e.preventDefault();
      const all = this._relFingers(e.touches);
      if (all.length >= 2) {
        const fingers = all.slice(0, 2).map(f => this._norm(f));
        this._state = { mode: 'multi', lastSendMs: 0 };
        this.input.touchDown(fingers);
        if (this.overlay) this.overlay.setFingers(all.slice(0, 2).map(f => ({ x: f.vx, y: f.vy })));
        this.log(`touchDown 2f`);
      } else if (all.length === 1) {
        const f = all[0];
        this._state = { mode: 'single', lastSendMs: 0 };
        this.input.touchDown([this._norm(f)]);
      }
    }

    _onMove(e) {
      e.preventDefault();
      const all = this._relFingers(e.touches);
      if (!this._state) return;

      const now = performance.now();
      if (now - this._state.lastSendMs < 16) return;

      if (this._state.mode === 'multi' && all.length >= 2) {
        const fingers = all.slice(0, 2).map(f => this._norm(f));
        this._state.lastSendMs = now;
        this.input.touchMove(fingers);
        if (this.overlay) this.overlay.setFingers(all.slice(0, 2).map(f => ({ x: f.vx, y: f.vy })));
      } else if (this._state.mode === 'single' && all.length === 1) {
        const f = all[0];
        this._state.lastSendMs = now;
        this.input.touchMove([this._norm(f)]);
      } else if (this._state.mode === 'single' && all.length >= 2) {
        // Upgrade: second finger landed — end single, start multi.
        this.input.touchUp([this._norm(all[0])]);
        const fingers = all.slice(0, 2).map(f => this._norm(f));
        this._state = { mode: 'multi', lastSendMs: 0 };
        this.input.touchDown(fingers);
        if (this.overlay) this.overlay.setFingers(all.slice(0, 2).map(f => ({ x: f.vx, y: f.vy })));
      }
    }

    _onEnd(e) {
      e.preventDefault();
      if (!this._state) return;
      const remaining = this._relFingers(e.touches);
      const ended = this._relFingers(e.changedTouches);

      if (this._state.mode === 'multi') {
        const source = remaining.length >= 2 ? remaining : ended;
        const fingers = source.slice(0, 2).map(f => this._norm(f));
        // Pad to 2 fingers if only one changedTouch came through.
        while (fingers.length < 2) fingers.push(fingers[0] || { x: 0.5, y: 0.5 });
        this.input.touchUp(fingers);
        if (this.overlay) this.overlay.clear();
        this.log('touchUp 2f');
      } else if (this._state.mode === 'single') {
        const f = ended[0] || { vx: 0, vy: 0, vw: 1, vh: 1 };
        this.input.touchUp([this._norm(f)]);
      }
      this._state = null;
    }
  }

  // --- Export ---
  global.SimInput = SimInput;
  global.PinchOverlay = PinchOverlay;
  global.MouseGestureSource = MouseGestureSource;
  global.TouchGestureSource = TouchGestureSource;

  // Ripple keyframes (shared).
  if (!document.getElementById('simRippleStyle')) {
    const s = document.createElement('style');
    s.id = 'simRippleStyle';
    s.textContent = '@keyframes simRipple { 0% { opacity:1;width:10px;height:10px;border-width:2px } 50% { opacity:0.7;width:30px;height:30px;border-width:2px } 100% { opacity:0;width:50px;height:50px;border-width:1px } }';
    document.head.appendChild(s);
  }
})(window);
