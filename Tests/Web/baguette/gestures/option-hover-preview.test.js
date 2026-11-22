import test from 'node:test';
import assert from 'node:assert/strict';
import { OptionHoverPreview } from '../../../../Sources/Baguette/Resources/Web/baguette/gestures/option-hover-preview.js';
import { FakeElement, fakeEvent, fakeScreen, fakeOverlay } from '../../helpers/fake-dom.js';

// OptionHoverPreview registers window-level keydown/keyup/blur listeners
// on the global `window`, so the fake "window" must be fireable too — a
// second FakeElement plays that role, installed for the test and removed
// after it.
function build() {
  const fakeWindow = new FakeElement();
  globalThis.window = fakeWindow;
  return { OptionHoverPreview, fakeWindow };
}

test.afterEach(() => { delete globalThis.window; });

test('should show the cursor mirrored through the centre when hovering with Option held', () => {
  const { OptionHoverPreview, fakeWindow } = build();
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const preview = new OptionHoverPreview(screen, { overlay });
  preview.attach(el);

  el.fire('mouseenter', fakeEvent({ clientX: 100, clientY: 200 }));
  fakeWindow.fire('keydown', fakeEvent({ key: 'Alt' }));

  assert.equal(overlay.calls.setFingers.length, 1);
  const [f1, f2] = overlay.calls.setFingers[0];
  assert.equal(f1.x, 100);
  assert.equal(f1.y, 200);
  assert.equal(f2.x, 390 - 100);
  assert.equal(f2.y, 844 - 200);
});

test('should show a parallel pair straddling the centre when hovering with Option and Shift held', () => {
  const { OptionHoverPreview, fakeWindow } = build();
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const preview = new OptionHoverPreview(screen, { overlay });
  preview.attach(el);

  el.fire('mouseenter', fakeEvent({ clientX: 100, clientY: 200 }));
  fakeWindow.fire('keydown', fakeEvent({ key: 'Alt' }));
  fakeWindow.fire('keydown', fakeEvent({ key: 'Shift' }));

  const [f1, f2] = overlay.calls.setFingers.at(-1);
  assert.equal(f1.y, f2.y, 'parallel pair sits on a horizontal line');
  assert.ok(f1.x !== f2.x);
});

test('should clear the overlay when Option is released', () => {
  const { OptionHoverPreview, fakeWindow } = build();
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const preview = new OptionHoverPreview(screen, { overlay });
  preview.attach(el);

  el.fire('mouseenter', fakeEvent({ clientX: 100, clientY: 200 }));
  const clearsBeforeKeyup = overlay.calls.clear; // mouseenter clears once, before Option is held
  fakeWindow.fire('keydown', fakeEvent({ key: 'Alt' }));
  assert.equal(overlay.calls.clear, clearsBeforeKeyup);

  fakeWindow.fire('keyup', fakeEvent({ key: 'Alt' }));
  assert.equal(overlay.calls.clear, clearsBeforeKeyup + 1);
});

test('should leave the overlay alone when the mouse moves without Option', () => {
  const { OptionHoverPreview } = build();
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const preview = new OptionHoverPreview(screen, { overlay });
  preview.attach(el);

  el.fire('mouseenter', fakeEvent({ clientX: 100, clientY: 200 }));
  el.fire('mousemove', fakeEvent({ clientX: 110, clientY: 210 }));

  assert.equal(overlay.calls.setFingers.length, 0);
  assert.equal(overlay.calls.clear, 2, 'both mouseenter and mousemove clear the stale preview since Option is never held');
});

test('should hold the preview while a drag is active and refresh it after', () => {
  const { OptionHoverPreview, fakeWindow } = build();
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const preview = new OptionHoverPreview(screen, { overlay });
  preview.attach(el);

  el.fire('mouseenter', fakeEvent({ clientX: 100, clientY: 200 }));
  fakeWindow.fire('keydown', fakeEvent({ key: 'Alt' }));
  const before = overlay.calls.setFingers.length;

  preview.setDragActive(true);
  el.fire('mousemove', fakeEvent({ clientX: 150, clientY: 250 }));
  assert.equal(overlay.calls.setFingers.length, before, 'no preview repaint while a gesture is active');

  preview.setDragActive(false);
  assert.equal(overlay.calls.setFingers.length, before + 1, 'refreshes immediately once the gesture ends');
});

test('should release the modifiers and clear the overlay when the window loses focus', () => {
  const { OptionHoverPreview, fakeWindow } = build();
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const preview = new OptionHoverPreview(screen, { overlay });
  preview.attach(el);

  el.fire('mouseenter', fakeEvent({ clientX: 100, clientY: 200 }));
  const clearsBeforeBlur = overlay.calls.clear; // mouseenter clears once, before Option is held
  fakeWindow.fire('keydown', fakeEvent({ key: 'Alt' }));
  fakeWindow.fire('blur', fakeEvent());

  assert.equal(overlay.calls.clear, clearsBeforeBlur + 1);
  const setFingersBeforeMove = overlay.calls.setFingers.length;

  // Option no longer considered held — a later mousemove shows nothing new.
  el.fire('mousemove', fakeEvent({ clientX: 120, clientY: 220 }));
  assert.equal(overlay.calls.setFingers.length, setFingersBeforeMove);
});

test('should hide the preview when the mouse leaves', () => {
  const { OptionHoverPreview, fakeWindow } = build();
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const preview = new OptionHoverPreview(screen, { overlay });
  preview.attach(el);

  el.fire('mouseenter', fakeEvent({ clientX: 100, clientY: 200 }));
  const clearsBeforeLeave = overlay.calls.clear; // mouseenter clears once, before Option is held
  fakeWindow.fire('keydown', fakeEvent({ key: 'Alt' }));
  assert.equal(overlay.calls.setFingers.length, 1);

  el.fire('mouseleave', fakeEvent());
  assert.equal(overlay.calls.clear, clearsBeforeLeave + 1);
});

test('should ignore further input once detached', () => {
  const { OptionHoverPreview, fakeWindow } = build();
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const preview = new OptionHoverPreview(screen, { overlay });
  preview.attach(el);
  preview.detach();

  el.fire('mouseenter', fakeEvent({ clientX: 100, clientY: 200 }));
  fakeWindow.fire('keydown', fakeEvent({ key: 'Alt' }));
  assert.equal(overlay.calls.setFingers.length, 0);
});
