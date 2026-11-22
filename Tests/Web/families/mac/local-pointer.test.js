import test from 'node:test';
import assert from 'node:assert/strict';
import { LocalPointer } from '../../../../Sources/Baguette/Resources/Web/families/mac/internal/local-pointer.js';

const screen = { left: 100, top: 50, width: 400, height: 800 };

test('should draw the pointer where the finger is on the screen, at once', () => {
  assert.deepEqual(LocalPointer.place({ clientX: 300, clientY: 450 }, screen), { left: 50, top: 50 });
});

test('should keep the pointer on the screen when the finger slides off its edge', () => {
  assert.deepEqual(LocalPointer.place({ clientX: 50, clientY: 900 }, screen), { left: 0, top: 100 });
});

test('should draw a pointer for a finger or a pen, and leave a mouse its own', () => {
  assert.equal(LocalPointer.draws('touch'), true);
  assert.equal(LocalPointer.draws('pen'), true);
  assert.equal(LocalPointer.draws('mouse'), false);
});


test('should draw a shape so its hotspot, not its corner, is under the finger', () => {
  assert.deepEqual(LocalPointer.offset({ hotspot: { x: 12, y: 11 } }), { left: -12, top: -11 });
});

test('should stop following the finger once detached', () => {
  const listeners = new Map();
  const area = {
    style: {},
    appendChild() {},
    addEventListener(type, fn) { listeners.set(type, fn); },
    removeEventListener(type, fn) { if (listeners.get(type) === fn) listeners.delete(type); },
    getBoundingClientRect: () => screen,
  };
  const saved = globalThis.document;
  globalThis.document = { createElement: () => ({ style: {}, remove() {} }) };
  try {
    const pointer = LocalPointer.attach(area);
    assert.deepEqual([...listeners.keys()].sort(), ['pointerdown', 'pointermove']);
    pointer.detach();
    assert.equal(listeners.size, 0);
  } finally {
    globalThis.document = saved;
  }
});
