import test from 'node:test';
import assert from 'node:assert/strict';
import { macPointer } from '../../../../Sources/Baguette/Resources/Web/families/mac/internal/pointer.js';
import { framesThatFit, rememberFrame } from '../../../../Sources/Baguette/Resources/Web/families/mac/internal/frame-picker.js';

// A Mac display's own roles: the page draws its pointer, in the Mac's shape,
// and offers the Mac frames that fit it.

test('should draw the Mac\'s pointer over the screen, in its real shape, and hover with the mouse', () => {
  const saved = globalThis.window;
  const did = [];
  let follow;
  globalThis.window = { Baguette: {
    _LocalPointer: { attach: (area) => { did.push(['pointer', area]); return { setShape: (s) => did.push(['shape', s.cursor]) }; } },
    _HoverGestureSource: class { constructor(screen) { did.push(['hover', screen]); } attach(area) { did.push(['hover-on', area]); } },
    _PointerShape: { follow: (fn) => { follow = fn; }, cursor: (shape, density) => shape.id + '@' + density },
  } };
  try {
    const view = { screenArea: 'AREA', screen: 'SCREEN' };
    macPointer.follow(view);
    follow({ id: 'ibeam' }, 2);
    assert.deepEqual(did, [['pointer', 'AREA'], ['hover', 'SCREEN'], ['hover-on', 'AREA'], ['shape', 'ibeam@2']]);
  } finally {
    globalThis.window = saved;
  }
});

test('should offer the Mac frames that fit the display\'s own screen', async () => {
  const asked = [];
  const wire = {
    path: (id, suffix) => '/devices/' + id + suffix,
    json: async (url) => { asked.push(url); return url.startsWith('/devices/') ? { screen: { rect: { width: 2560, height: 1440 } } } : { frames: ['iMac'] }; },
  };
  assert.deepEqual(await framesThatFit('D', wire), ['iMac']);
  assert.deepEqual(asked, ['/devices/D/definition.json', '/mac-frames.json?width=2560&height=1440']);
});

test('should offer no frame when the display can\'t say its size, or the server answers nothing', async () => {
  assert.deepEqual(await framesThatFit('D', { path: () => '/x', json: async () => ({}) }), []);
  assert.deepEqual(await framesThatFit('D', { path: () => '/x', json: async () => { throw new Error('offline'); } }), []);
});

test('should remember a picked frame for its display, and forget it on no frame', () => {
  const stored = {};
  const storage = { setItem: (k, v) => { stored[k] = v; }, removeItem: (k) => { delete stored[k]; } };
  rememberFrame(storage, 'D', 'iMac 27-inch');
  assert.deepEqual(stored, { 'baguette.twin.chrome.D': 'iMac 27-inch' });
  rememberFrame(storage, 'D', null);
  assert.deepEqual(stored, {});
});
