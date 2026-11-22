// FarmFocusWidth — adjustable width for the Device Farm focus pane.
//
// Owns only layout preference: pointer/keyboard input updates the CSS
// grid variable, and the last chosen width survives page reloads.
const STORAGE_KEY = 'baguette.farm.focusWidth';
const DEFAULT_WIDTH = 420;
const MIN_WIDTH = 260;
const MAX_WIDTH = 720;
const RAIL_WIDTH = 280;
const RESIZER_WIDTH = 9;
const MIN_GRID_WIDTH = 320;
const KEY_STEP = 20;

function FarmFocusWidth(main, handle) {
  this.main = main;
  this.handle = handle;
  this.width = DEFAULT_WIDTH;
  this.drag = null;
}

FarmFocusWidth.prototype.start = function () {
  this.set(this._storedWidth(), false);

  this.handle.addEventListener('pointerdown', event => {
    if (event.button !== 0) return;
    this.drag = { x: event.clientX, width: this.width };
    this.handle.setPointerCapture(event.pointerId);
    document.body.classList.add('focus-resizing');
    event.preventDefault();
  });

  this.handle.addEventListener('pointermove', event => {
    if (!this.drag) return;
    this.set(this.drag.width + this.drag.x - event.clientX, false);
  });

  const finishDrag = event => {
    if (!this.drag) return;
    this.drag = null;
    document.body.classList.remove('focus-resizing');
    if (this.handle.hasPointerCapture(event.pointerId)) {
      this.handle.releasePointerCapture(event.pointerId);
    }
    this._store();
  };
  this.handle.addEventListener('pointerup', finishDrag);
  this.handle.addEventListener('pointercancel', finishDrag);

  this.handle.addEventListener('keydown', event => {
    if (event.key === 'ArrowLeft') this.set(this.width + KEY_STEP);
    else if (event.key === 'ArrowRight') this.set(this.width - KEY_STEP);
    else if (event.key === 'Home') this.set(MIN_WIDTH);
    else if (event.key === 'End') this.set(this._maximumWidth());
    else return;
    event.preventDefault();
  });

  this.handle.addEventListener('dblclick', () => this.set(DEFAULT_WIDTH));
  window.addEventListener('resize', () => this.set(this.width, false));
};

FarmFocusWidth.prototype.set = function (requested, persist) {
  const width = Math.round(Math.max(MIN_WIDTH, Math.min(this._maximumWidth(), requested)));
  this.width = width;
  this.main.style.setProperty('--focus-width', width + 'px');
  this.handle.setAttribute('aria-valuenow', String(width));
  this.handle.setAttribute('aria-valuemax', String(this._maximumWidth()));
  if (persist !== false) this._store();
};

FarmFocusWidth.prototype._maximumWidth = function () {
  const available = this.main.clientWidth - RAIL_WIDTH - RESIZER_WIDTH - MIN_GRID_WIDTH;
  return Math.max(MIN_WIDTH, Math.min(MAX_WIDTH, available));
};

FarmFocusWidth.prototype._storedWidth = function () {
  try {
    const value = Number(window.localStorage.getItem(STORAGE_KEY));
    return Number.isFinite(value) && value > 0 ? value : DEFAULT_WIDTH;
  } catch (_) {
    return DEFAULT_WIDTH;
  }
};

FarmFocusWidth.prototype._store = function () {
  try { window.localStorage.setItem(STORAGE_KEY, String(this.width)); } catch (_) {}
};

export { FarmFocusWidth };
