// WheelGestureSource — trackpad/mouse wheel as a synthesized 2-finger
// pinch (Ctrl+wheel) or pan (plain wheel), auto-closing after a short
// idle window since wheel events have no natural "finger up".
import { AttachableEventSource } from './attachable-event-source.js';

const BASE_SPREAD_PT = 80; // sim-pt for the synthesized finger pair
const WHEEL_IDLE_MS = 120; // wheel idle → close 2-finger

class WheelGestureSource extends AttachableEventSource {
  constructor(screen, { overlay } = {}) {
    super(screen);
    this.overlay = overlay || null;
  }

  _bind() {
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
        x: (vx / r.width) * width,
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
        const shiftX = (-e.deltaX / r.width) * width;
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
          const dxPx = (state.f1.x - centre.x) / width * r.width;
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
}

export { WheelGestureSource };

