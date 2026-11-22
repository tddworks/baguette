import test from 'node:test';
import assert from 'node:assert/strict';
import { rotationView } from '../../../Sources/Baguette/Resources/Web/page/internal/rotation-view.js';

// A turned device's frame is drawn rotated: each step a quarter turn
// clockwise, always forward (so the animation never spins back the long
// way); a panel that arrives already turned is set straight, without a turn.

function frame() {
  const attributes = {};
  const wrappers = [{ style: { transform: '', transition: 'all .3s' }, offsetWidth: 1 }];
  return {
    wrappers, attributes,
    setAttribute: (k, v) => { attributes[k] = v; },
    removeAttribute: (k) => { delete attributes[k]; },
    querySelectorAll: () => wrappers,
  };
}

const CYCLE = ['portrait', 'landscape-left', 'portrait-upside-down', 'landscape-right'];

test('should step through the cycle a quarter turn forward each time, back to portrait after four', () => {
  const drawn = frame();
  const view = rotationView({ frame: () => drawn, cycle: CYCLE, laidOut: () => {} });
  assert.deepEqual([view.next(), view.next(), view.next(), view.next()],
    ['landscape-left', 'portrait-upside-down', 'landscape-right', 'portrait']);
});

test('should draw the frame turned forward, saying which way it faces, and none when back in portrait', () => {
  const drawn = frame();
  const view = rotationView({ frame: () => drawn, cycle: CYCLE, laidOut: () => {} });
  view.apply('landscape-left');
  assert.equal(drawn.wrappers[0].style.transform, 'rotate(90deg)');
  assert.equal(drawn.attributes['data-orientation'], 'landscape-left');
  view.apply('portrait-upside-down'); view.apply('landscape-right'); view.apply('portrait');
  assert.equal(drawn.wrappers[0].style.transform, 'rotate(360deg)');
  assert.equal(drawn.attributes['data-orientation'], undefined);
  assert.equal(view.current, 'portrait');
});

test('should keep the frame as it is when asked for the orientation it already shows', () => {
  const drawn = frame();
  const view = rotationView({ frame: () => drawn, cycle: CYCLE, laidOut: () => {} });
  view.apply('landscape-left');
  view.apply('landscape-left');
  assert.equal(drawn.wrappers[0].style.transform, 'rotate(90deg)');
});

test('should set a panel that arrives turned straight, without animating, and step on from there', () => {
  const drawn = frame();
  const view = rotationView({ frame: () => drawn, cycle: CYCLE, laidOut: () => {} });
  view.snap('landscape-right');
  assert.equal(drawn.wrappers[0].style.transform, 'rotate(270deg)');
  assert.equal(drawn.wrappers[0].style.transition, 'all .3s');
  assert.equal(view.next(), 'portrait');
});

test('should lay the page out again each time the frame turns', () => {
  let laidOut = 0;
  const view = rotationView({ frame: () => frame(), cycle: CYCLE, laidOut: () => { laidOut += 1; } });
  view.apply('landscape-left');
  view.snap('portrait');
  assert.equal(laidOut, 2);
});
