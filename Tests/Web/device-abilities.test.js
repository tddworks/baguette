'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web', 'device-abilities.js'
);

function DeviceAbilities() {
  return loadBrowserModule(MODULE_PATH).Baguette._DeviceAbilities;
}

const SIMULATOR = ['power', 'screen', 'touch', 'press', 'key', 'scroll', 'displays', 'hinge',
  'accessibility', 'logs', 'orientation', 'statusBar', 'interface', 'location', 'motion',
  'network', 'camera', 'pasteboard', 'apps', 'notify', 'defaults', 'photos', 'shake'];
const PHONE = ['screen', 'touch', 'accessibility', 'pasteboard'];

test('should show every control to a device that can do everything', () => {
  const hidden = DeviceAbilities().hidden(DeviceAbilities().controls(), SIMULATOR);
  assert.deepEqual(hidden, []);
});

test('should hide the controls a phone on a cable has no ability for', () => {
  const hidden = DeviceAbilities().hidden(DeviceAbilities().controls(), PHONE);
  assert.ok(hidden.includes('nativeRotate'));
  assert.ok(hidden.includes('nativeHome'));
  assert.ok(hidden.includes('nativeCameraToggle'));
  assert.ok(hidden.includes('nativeLogsToggle'));
  assert.ok(!hidden.includes('nativeAxToggle'));
});

test('should keep a control that needs no ability', () => {
  assert.equal(DeviceAbilities().shows('nativeScreenshot', []), true);
});

test('should say whether the device has an ability', () => {
  assert.equal(DeviceAbilities().has(PHONE, 'hinge'), false);
  assert.equal(DeviceAbilities().has(SIMULATOR, 'hinge'), true);
  assert.equal(DeviceAbilities().has(undefined, 'hinge'), false);
});
