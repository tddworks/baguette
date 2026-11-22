import test from 'node:test';
import assert from 'node:assert/strict';
import { HandheldMode } from '../../../Sources/Baguette/Resources/Web/handheld/handheld-mode.js';

// iPhone 17 Pro Max points, the screen the stream carries.
const PRO_MAX = { width: 440, height: 956 };

// --- wanted -----------------------------------------------------------

test('should hold the phone in hand when the link asks for handheld', () => {
  assert.equal(HandheldMode.wanted({ search: '?handheld=1', standalone: false }), true);
});

test('should show the desk view when the link does not ask for handheld', () => {
  assert.equal(HandheldMode.wanted({ search: '', standalone: false }), false);
});

test('should show the desk view when the link turns handheld off', () => {
  assert.equal(HandheldMode.wanted({ search: '?handheld=0', standalone: false }), false);
});

test('should hold the phone in hand when opened from the Home Screen', () => {
  assert.equal(HandheldMode.wanted({ search: '', standalone: true }), true);
});

// --- href -------------------------------------------------------------

test('should remember handheld in the address so a Home Screen icon reopens it', () => {
  assert.equal(
    HandheldMode.href('http://mac.local:8421/simulators/ABC', true),
    'http://mac.local:8421/simulators/ABC?handheld=1'
  );
});

test('should keep the rest of the address when remembering handheld', () => {
  assert.equal(
    HandheldMode.href('http://mac.local:8421/simulators/ABC?format=mjpeg#x', true),
    'http://mac.local:8421/simulators/ABC?format=mjpeg&handheld=1#x'
  );
});

test('should forget handheld in the address when leaving it', () => {
  assert.equal(
    HandheldMode.href('http://mac.local:8421/simulators/ABC?format=mjpeg&handheld=1', false),
    'http://mac.local:8421/simulators/ABC?format=mjpeg'
  );
});

// --- fit --------------------------------------------------------------

test('should fill the glass edge to edge when the phone matches the simulated one', () => {
  const box = HandheldMode.fit({
    viewport: { width: 440, height: 956 }, screen: PRO_MAX, orientation: 'portrait',
  });
  assert.deepEqual(box, { width: 440, height: 956 });
});

test('should fill the height and leave bars at the sides when the browser bars shorten the view', () => {
  const box = HandheldMode.fit({
    viewport: { width: 440, height: 740 }, screen: PRO_MAX, orientation: 'portrait',
  });
  assert.equal(box.height, 740);
  assert.ok(Math.abs(box.width - 740 * 440 / 956) < 0.001);
});

test('should fill the width and leave bars above and below when the view is taller than the screen', () => {
  const box = HandheldMode.fit({
    viewport: { width: 400, height: 1000 }, screen: PRO_MAX, orientation: 'portrait',
  });
  assert.equal(box.width, 400);
  assert.ok(Math.abs(box.height - 400 * 956 / 440) < 0.001);
});

test('should size the screen to fit sideways when the simulator is turned to landscape', () => {
  // The box is still the portrait screen; its rotated footprint
  // (height across, width down) is what has to fit the view.
  const box = HandheldMode.fit({
    viewport: { width: 956, height: 440 }, screen: PRO_MAX, orientation: 'landscape-left',
  });
  assert.deepEqual(box, { width: 440, height: 956 });
});

test('should keep the whole sideways screen in view when a phone held upright shows landscape', () => {
  const box = HandheldMode.fit({
    viewport: { width: 440, height: 956 }, screen: PRO_MAX, orientation: 'landscape-right',
  });
  // Rotated footprint is box.height wide — it must not exceed the view width.
  assert.equal(box.height, 440);
  assert.ok(Math.abs(box.width - 440 * 440 / 956) < 0.001);
});

// --- fullscreenRoute --------------------------------------------------

test('should already be full screen when opened from the Home Screen', () => {
  assert.equal(
    HandheldMode.fullscreenRoute({ standalone: true, pageFullscreen: false }),
    'standalone'
  );
});

test('should ask the browser for fullscreen when the browser lets a page have it', () => {
  assert.equal(
    HandheldMode.fullscreenRoute({ standalone: false, pageFullscreen: true }),
    'browser'
  );
});

test('should point to the Home Screen when the browser keeps fullscreen for video', () => {
  // Every iPhone browser: WebKit, `document.fullscreenEnabled` false.
  assert.equal(
    HandheldMode.fullscreenRoute({ standalone: false, pageFullscreen: false }),
    'home-screen'
  );
});
