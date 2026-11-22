import test from 'node:test';
import assert from 'node:assert/strict';
import { macPointerWith } from '../../../../Sources/Baguette/Resources/Web/families/mac/internal/pointer.js';
import { framesThatFit, rememberFrame } from '../../../../Sources/Baguette/Resources/Web/families/mac/internal/frame-picker.js';

// A Mac display's own roles: the page draws its pointer, in the Mac's shape,
// and offers the Mac frames that fit it.

test('should draw the Mac\'s pointer over the screen, in its real shape, and hover with the mouse', () => {
  const did = [];
  let follow;
  const macPointer = macPointerWith({
    LocalPointer: { attach: (area) => { did.push(['pointer', area]); return { setShape: (s) => did.push(['shape', s.cursor]) }; } },
    HoverGestureSource: class { constructor(screen) { did.push(['hover', screen]); } attach(area) { did.push(['hover-on', area]); } },
    PointerShape: { follow: (fn) => { follow = fn; }, cursor: (shape, density) => shape.id + '@' + density },
  });
  const view = { screenArea: 'AREA', screen: 'SCREEN' };
  macPointer.follow(view);
  follow({ id: 'ibeam' }, 2);
  assert.deepEqual(did, [['pointer', 'AREA'], ['hover', 'SCREEN'], ['hover-on', 'AREA'], ['shape', 'ibeam@2']]);
});

test('should offer the Mac frames that fit the display\'s own screen', async () => {
  const asked = [];
  const devices = {
    definition: async (id) => { asked.push('definition ' + id); return { screen: { rect: { width: 2560, height: 1440 } } }; },
    framesFitting: async (w, h) => { asked.push('frames ' + w + 'x' + h); return ['iMac']; },
  };
  assert.deepEqual(await framesThatFit('D', devices), ['iMac']);
  assert.deepEqual(asked, ['definition D', 'frames 2560x1440']);
});

test('should offer no frame when the display can\'t say its size, or the server answers nothing', async () => {
  assert.deepEqual(await framesThatFit('D', { definition: async () => ({}) }), []);
  assert.deepEqual(await framesThatFit('D', { definition: async () => { throw new Error('offline'); } }), []);
});

test('should remember a picked frame for its display, and forget it on no frame', () => {
  const stored = {};
  const storage = { setItem: (k, v) => { stored[k] = v; }, removeItem: (k) => { delete stored[k]; } };
  rememberFrame(storage, 'D', 'iMac 27-inch');
  assert.deepEqual(stored, { 'baguette.twin.chrome.D': 'iMac 27-inch' });
  rememberFrame(storage, 'D', null);
  assert.deepEqual(stored, {});
});
