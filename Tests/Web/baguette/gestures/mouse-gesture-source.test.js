import test from 'node:test';
import assert from 'node:assert/strict';
import { MouseGestureSource } from '../../../../Sources/Baguette/Resources/Web/baguette/gestures/mouse-gesture-source.js';
import {
  FakeElement, fakeEvent, fakeScreen, fakeOverlay, installFakeDocument,
} from '../../helpers/fake-dom.js';

function mouseEvent(overrides) {
  return fakeEvent({ altKey: false, shiftKey: false, clientX: 0, clientY: 0, ...overrides });
}

test('should tap once and ripple when a click does not move', (t) => {
  const doc = installFakeDocument();
  t.after(() => doc.uninstall());
  const MGS = MouseGestureSource; // loading the module itself injects the ripple keyframes once
  const createdAtLoad = doc.createdCount;
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new MGS(screen);
  source.attach(el);

  el.fire('mousedown', mouseEvent({ clientX: 100, clientY: 200 }));
  el.fire('mouseup', mouseEvent({ clientX: 100, clientY: 200 }));

  assert.equal(screen.calls.tap.length, 1);
  assert.ok(Math.abs(screen.calls.tap[0].point.x - 100) < 1e-6);
  assert.ok(Math.abs(screen.calls.tap[0].point.y - 200) < 1e-6);
  assert.equal(screen.calls.touchDown.length, 0, 'a plain tap never streams touch1');
  assert.equal(doc.createdCount, createdAtLoad + 1, 'the tap ripple was created');
});

test('should stream a one-finger touch when a drag passes the threshold', () => {
  const MGS = MouseGestureSource;
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new MGS(screen);
  source.attach(el);

  el.fire('mousedown', mouseEvent({ clientX: 100, clientY: 200 }));
  el.fire('mousemove', mouseEvent({ clientX: 120, clientY: 200 })); // past DRAG_THRESHOLD_PX
  el.fire('mouseup', mouseEvent({ clientX: 120, clientY: 200 }));

  assert.equal(screen.calls.touchDown.length, 1);
  assert.equal(screen.calls.touchDown[0].fingers.length, 1);
  assert.equal(screen.calls.touchMove.length, 1);
  assert.equal(screen.calls.touchUp.length, 1);
  assert.equal(screen.calls.tap.length, 0);
});

test('should stream a touch tagged with the bottom edge at once when a press lands in its band', () => {
  const MGS = MouseGestureSource;
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new MGS(screen, { getOrientation: () => 'portrait' });
  source.attach(el);

  // yNorm = 800/844 ≈ 0.948 — inside the mouse bottom band (0.93).
  el.fire('mousedown', mouseEvent({ clientX: 195, clientY: 800 }));
  assert.equal(screen.calls.touchDown[0].opts.edge, 'bottom');

  el.fire('mousemove', mouseEvent({ clientX: 195, clientY: 810 }));
  assert.equal(screen.calls.touchMove[0].opts.edge, 'bottom');

  el.fire('mouseup', mouseEvent({ clientX: 195, clientY: 810 }));
  assert.equal(screen.calls.touchUp[0].opts.edge, 'bottom');
});

test('should pinch with two fingers mirrored through the centre when dragged with Option', () => {
  const MGS = MouseGestureSource;
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new MGS(screen, { overlay });
  source.attach(el);

  el.fire('mousedown', mouseEvent({ altKey: true, clientX: 100, clientY: 200 }));
  const [f1, f2] = screen.calls.touchDown[0].fingers;
  const centerX = 390 / 2, centerY = 844 / 2;
  assert.ok(Math.abs((f1.x + f2.x) / 2 - centerX) < 1e-6, 'fingers straddle the screen center');
  assert.ok(Math.abs((f1.y + f2.y) / 2 - centerY) < 1e-6);
  assert.ok(overlay.calls.setFingers.length >= 1, 'pinch preview painted on the overlay');

  el.fire('mouseup', mouseEvent({ altKey: true, clientX: 100, clientY: 200 }));
  assert.equal(screen.calls.touchUp.length, 1);
  assert.equal(overlay.calls.clear, 1);
});

test('should pan two fingers together when dragged with Option and Shift', () => {
  const MGS = MouseGestureSource;
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new MGS(screen);
  source.attach(el);

  el.fire('mousedown', mouseEvent({ altKey: true, shiftKey: true, clientX: 195, clientY: 400 }));
  const [downF1, downF2] = screen.calls.touchDown[0].fingers;
  assert.ok(Math.abs(downF1.y - downF2.y) < 1e-6, 'pan fingers start on a horizontal line');

  el.fire('mousemove', mouseEvent({ altKey: true, shiftKey: true, clientX: 245, clientY: 400 }));
  const [moveF1, moveF2] = screen.calls.touchMove.at(-1).fingers;
  assert.ok(moveF1.x > downF1.x, 'both fingers shifted right with the drag');
  assert.ok(moveF2.x > downF2.x);

  el.fire('mouseup', mouseEvent({ altKey: true, shiftKey: true, clientX: 245, clientY: 400 }));
  assert.equal(screen.calls.touchUp.length, 1);
});

test('should hold the touch when the press stays still past a long press', (t) => {
  const doc = installFakeDocument();
  t.after(() => doc.uninstall());
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const MGS = MouseGestureSource; // loading the module itself injects the ripple keyframes once
  const createdAtLoad = doc.createdCount;
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new MGS(screen);
  source.attach(el);

  el.fire('mousedown', mouseEvent({ clientX: 100, clientY: 200 }));
  assert.equal(screen.calls.touchDown.length, 0, 'no touch yet — still pending');

  t.mock.timers.tick(250);
  assert.equal(screen.calls.touchDown.length, 1, 'long press promoted pending to a touch1 stream');
  assert.equal(doc.createdCount, createdAtLoad + 1, 'a ripple marks the long-press moment');

  el.fire('mouseup', mouseEvent({ clientX: 100, clientY: 200 }));
  assert.equal(screen.calls.touchUp.length, 1);
  assert.equal(screen.calls.tap.length, 0, 'never collapses into a tap once held');
});

test('should start nothing when a press lands off the interactive surface', () => {
  const MGS = MouseGestureSource;
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new MGS(screen, {
    mapClientPoint: () => ({ x: 0, y: 0, xNorm: 0, yNorm: 0, inside: false }),
  });
  source.attach(el);

  el.fire('mousedown', mouseEvent({ clientX: 50, clientY: 50 }));
  el.fire('mousemove', mouseEvent({ clientX: 80, clientY: 80 }));
  el.fire('mouseup', mouseEvent({ clientX: 80, clientY: 80 }));

  assert.equal(screen.calls.touchDown.length, 0);
  assert.equal(screen.calls.tap.length, 0);
});

test('should report a drag while a gesture is active and none once it ends', (t) => {
  const doc = installFakeDocument();
  t.after(() => doc.uninstall());
  const MGS = MouseGestureSource;
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const changes = [];
  const source = new MGS(screen, { onDragChange: (active) => changes.push(active) });
  source.attach(el);

  el.fire('mousedown', mouseEvent({ clientX: 100, clientY: 200 }));
  el.fire('mouseup', mouseEvent({ clientX: 100, clientY: 200 }));

  assert.deepEqual(changes, [true, false]);
});

test('should start no new gesture once detached', () => {
  const MGS = MouseGestureSource;
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new MGS(screen);
  source.attach(el);
  source.detach();

  el.fire('mousedown', mouseEvent({ clientX: 100, clientY: 200 }));
  el.fire('mouseup', mouseEvent({ clientX: 100, clientY: 200 }));
  assert.equal(screen.calls.tap.length, 0);
});
