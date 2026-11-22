// OptionHoverPreview — holding Option (with the cursor over the screen)
// shows two virtual finger dots WITHOUT clicking, matching Apple
// Simulator.app: pinch preview = cursor + mirror-through-centre; pan
// preview = parallel finger pair at centre.
//
// Suppressed while a real mouse gesture is active (`setDragActive`) so
// it doesn't repaint the overlay out from under MouseGestureSource's own
// pinch/pan preview — call `setDragActive(true/false)` from there rather
// than having either class reach into the other's state.
import { AttachableEventSource } from './attachable-event-source.js';

const BASE_SPREAD_PT = 80; // sim-pt for the pan preview's finger pair

class OptionHoverPreview extends AttachableEventSource {
  constructor(screen, { overlay } = {}) {
    super(screen);
    this.overlay = overlay || null;
    this._optionHeld = false;
    this._shiftHeld = false;
    this._cursorVx = 0; this._cursorVy = 0;
    this._cursorInside = false;
    this._dragActive = false;
  }

  /** Called by MouseGestureSource when a real gesture starts/ends. */
  setDragActive(active) {
    this._dragActive = active;
    this._updatePreview();
  }

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

  _bind() {
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
}

export { OptionHoverPreview };

