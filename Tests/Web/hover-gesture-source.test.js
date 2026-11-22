'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModules } = require('./helpers/load-browser-module.js');

const WEB = path.join(__dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web', 'baguette', 'gestures');

function HoverGestureSource() {
  return loadBrowserModules([path.join(WEB, 'attachable-event-source.js'), path.join(WEB, 'hover-gesture-source.js')])
    .Baguette._HoverGestureSource;
}

/** A screen that remembers its hovers, and a frame clock the test advances. */
function setup() {
  const hovers = [];
  const frames = [];
  const screen = { size: { width: 603, height: 1311 }, hover: (at) => hovers.push(at) };
  const source = new (HoverGestureSource())(screen, { schedule: (fn) => frames.push(fn) });
  source._el = { getBoundingClientRect: () => ({ left: 100, top: 50, width: 402, height: 874 }) };
  const frame = () => frames.splice(0).forEach((fn) => fn());
  return { source, hovers, frame };
}

const move = (clientX, clientY, extra = {}) => ({ clientX, clientY, pointerType: 'mouse', buttons: 0, ...extra });

test('should hover where the mouse is, in the screen\'s own points', () => {
  const { source, hovers, frame } = setup();
  source.moved(move(301, 487));
  frame();
  assert.deepEqual(hovers, [{ x: 301.5, y: 655.5 }]);
});

test('should send only the newest hover once a frame', () => {
  const { source, hovers, frame } = setup();
  source.moved(move(110, 60));
  source.moved(move(200, 100));
  source.moved(move(301, 487));
  frame();
  assert.equal(hovers.length, 1);
  assert.deepEqual(hovers[0], { x: 301.5, y: 655.5 });
});

test('should not hover while a button is down, or for a finger', () => {
  const { source, hovers, frame } = setup();
  source.moved(move(150, 100, { buttons: 1 }));
  source.moved(move(150, 100, { pointerType: 'touch' }));
  frame();
  assert.deepEqual(hovers, []);
});
