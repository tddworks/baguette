'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(__dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web', 'pointer-shape.js');

function PointerShape() {
  return loadBrowserModule(MODULE_PATH).Baguette._PointerShape;
}

const ibeam = { type: 'pointer', id: '3de4a52b', hotspot: [12, 11], size: [23, 22] };

test('should read the Mac pointer\'s shape from the socket, and nothing else', () => {
  assert.deepEqual(PointerShape().fromMessage(JSON.stringify(ibeam)),
    { id: '3de4a52b', image: '/mac/pointer/3de4a52b.png', hotspot: { x: 12, y: 11 }, size: { width: 23, height: 22 } });
  assert.equal(PointerShape().fromMessage('{"type":"log"}'), null);
  assert.equal(PointerShape().fromMessage('not json'), null);
});

test('should give the browser\'s pointer the Mac\'s shape, at its density, pointing with its hotspot', () => {
  const shape = PointerShape().fromMessage(JSON.stringify(ibeam));
  assert.equal(PointerShape().cursor(shape, 2),
    '-webkit-image-set(url("/mac/pointer/3de4a52b.png") 2x) 12 11, default');
});

test('should say how dense a shape\'s image is from its pixels and its points', () => {
  assert.equal(PointerShape().density(46, { width: 23, height: 22 }), 2);
  assert.equal(PointerShape().density(0, { width: 23, height: 22 }), 1);
});
