import test from 'node:test';
import assert from 'node:assert/strict';
import { SafariGestureEventSource } from '../../../../Sources/Baguette/Resources/Web/baguette/gestures/safari-gesture-event-source.js';
import { FakeElement, fakeEvent, fakeScreen, fakeOverlay } from '../../helpers/fake-dom.js';

test('should open a two-finger stream straddling the centroid when a gesture starts', () => {
  const SGES = SafariGestureEventSource;
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new SGES(screen);
  source.attach(el);

  el.fire('gesturestart', fakeEvent({ clientX: 200, clientY: 400 }));

  assert.equal(screen.calls.touchDown.length, 1);
  const [f1, f2] = screen.calls.touchDown[0].fingers;
  const midX = (f1.x + f2.x) / 2, midY = (f1.y + f2.y) / 2;
  assert.ok(Math.abs(midX - 200) < 1e-6);
  assert.ok(Math.abs(midY - 400) < 1e-6);
});

test('should scale and turn the fingers around the centroid as the gesture changes', () => {
  const SGES = SafariGestureEventSource;
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new SGES(screen);
  source.attach(el);

  el.fire('gesturestart', fakeEvent({ clientX: 200, clientY: 400 }));
  el.fire('gesturechange', fakeEvent({ clientX: 200, clientY: 400, scale: 2, rotation: 90 }));

  const [f1, f2] = screen.calls.touchMove.at(-1).fingers;
  const spread = Math.hypot(f1.x - f2.x, f1.y - f2.y);
  // A 90° rotation swings the pair from horizontal onto (near) vertical.
  assert.ok(spread > 300, `expected the doubled-scale spread to exceed 300pt, got ${spread}`);
  assert.ok(Math.abs(f1.x - f2.x) < 1, 'a 90° rotation leaves almost no horizontal separation');
});

test('should close the stream and clear the overlay when the gesture ends', () => {
  const SGES = SafariGestureEventSource;
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new SGES(screen, { overlay });
  source.attach(el);

  el.fire('gesturestart', fakeEvent({ clientX: 200, clientY: 400 }));
  el.fire('gestureend', fakeEvent({ clientX: 200, clientY: 400, scale: 1, rotation: 0 }));

  assert.equal(screen.calls.touchUp.length, 1);
  assert.equal(overlay.calls.clear, 1);
});

test('should ignore a gesture change or end before any start', () => {
  const SGES = SafariGestureEventSource;
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new SGES(screen);
  source.attach(el);

  el.fire('gesturechange', fakeEvent({ clientX: 1, clientY: 1, scale: 1, rotation: 0 }));
  el.fire('gestureend', fakeEvent({ clientX: 1, clientY: 1, scale: 1, rotation: 0 }));

  assert.equal(screen.calls.touchMove.length, 0);
  assert.equal(screen.calls.touchUp.length, 0);
});

test('should open no new stream once detached', () => {
  const SGES = SafariGestureEventSource;
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new SGES(screen);
  source.attach(el);
  source.detach();

  el.fire('gesturestart', fakeEvent({ clientX: 200, clientY: 400 }));
  assert.equal(screen.calls.touchDown.length, 0);
});
