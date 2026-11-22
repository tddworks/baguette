'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web', 'local-pointer.js'
);

function LocalPointer() {
  return loadBrowserModule(MODULE_PATH).Baguette._LocalPointer;
}

const screen = { left: 100, top: 50, width: 400, height: 800 };

test('should draw the pointer where the finger is on the screen, at once', () => {
  assert.deepEqual(LocalPointer().place({ clientX: 300, clientY: 450 }, screen), { left: 50, top: 50 });
});

test('should keep the pointer on the screen when the finger slides off its edge', () => {
  assert.deepEqual(LocalPointer().place({ clientX: 50, clientY: 900 }, screen), { left: 0, top: 100 });
});

test('should draw a pointer for a finger or a pen, and leave a mouse its own', () => {
  assert.equal(LocalPointer().draws('touch'), true);
  assert.equal(LocalPointer().draws('pen'), true);
  assert.equal(LocalPointer().draws('mouse'), false);
});

