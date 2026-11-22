// SafariGestureEventSource — Safari's native gesturestart/change/end
// (2-finger pinch with rotation, no jsdom-visible touch data). Owns the
// pinch handoff from TouchGestureSource: when a second finger lands
// there, it abandons the touch1/touch2 wire path entirely and lets this
// class's native gesture* stream drive the pinch instead.
import { AttachableEventSource } from './attachable-event-source.js';

const BASE_SPREAD_PT = 80; // sim-pt for the synthesized finger pair
const MOVE_FLUSH_MS = 16;  // ~60 fps coalescing window

class SafariGestureEventSource extends AttachableEventSource {
  constructor(screen, { overlay } = {}) {
    super(screen);
    this.overlay = overlay || null;
  }

  _bind() {
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
        x: (vx / r.width) * width,
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
        x: (vx / r.width) * width,
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
}

export { SafariGestureEventSource };

