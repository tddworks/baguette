'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'sim-list', 'device-filter.js'
);

function DeviceFilter() {
  return loadBrowserModule(MODULE_PATH).Baguette._DeviceFilter;
}

test('compareVersions orders dotted numeric runtimes ascending', () => {
  const { compareVersions } = DeviceFilter();
  assert.ok(compareVersions('18.2', '18.4') < 0);
  assert.ok(compareVersions('18.4', '18.2') > 0);
  assert.equal(compareVersions('18.4', '18.4'), 0);
});

test('compareVersions treats a runtime with no digits as lower than any real version', () => {
  const { compareVersions } = DeviceFilter();
  assert.ok(compareVersions('', '18.0') < 0);
  assert.ok(compareVersions('nightly', '1.0') < 0);
});

test('latestRuntime picks the highest version among devices', () => {
  const { latestRuntime } = DeviceFilter();
  const devices = [{ runtime: '18.2' }, { runtime: '26.4' }, { runtime: '18.4' }];
  assert.equal(latestRuntime(devices), '26.4');
});

test('latestRuntime returns an empty string for no devices', () => {
  const { latestRuntime } = DeviceFilter();
  assert.equal(latestRuntime([]), '');
});

test('apply keeps only iPhone names for the iphones family', () => {
  const DF = DeviceFilter();
  const devices = [
    { name: 'iPhone 17 Pro', state: 'Booted', runtime: '26.4', id: 'A' },
    { name: 'iPad Pro 13-inch (M5)', state: 'Booted', runtime: '26.4', id: 'B' },
  ];
  const result = new DF({ family: 'iphones', runtime: 'all', search: '' }).apply(devices);
  assert.deepEqual(result.map((d) => d.id), ['A']);
});

test('apply keeps only iPad names for the ipads family', () => {
  const DF = DeviceFilter();
  const devices = [
    { name: 'iPhone 17 Pro', state: 'Booted', runtime: '26.4', id: 'A' },
    { name: 'iPad Pro 13-inch (M5)', state: 'Booted', runtime: '26.4', id: 'B' },
  ];
  const result = new DF({ family: 'ipads', runtime: 'all', search: '' }).apply(devices);
  assert.deepEqual(result.map((d) => d.id), ['B']);
});

test('apply does not filter by name for the "all" family', () => {
  const DF = DeviceFilter();
  const devices = [
    { name: 'iPhone 17 Pro', state: 'Booted', runtime: '26.4', id: 'A' },
    { name: 'iPad Pro 13-inch (M5)', state: 'Booted', runtime: '26.4', id: 'B' },
  ];
  const result = new DF({ family: 'all', runtime: 'all', search: '' }).apply(devices);
  assert.deepEqual(result.map((d) => d.id).sort(), ['A', 'B']);
});

test('apply with runtime "latest" keeps only devices on the highest runtime', () => {
  const DF = DeviceFilter();
  const devices = [
    { name: 'iPhone 17 Pro', state: 'Booted', runtime: '18.4', id: 'A' },
    { name: 'iPhone 17 Pro', state: 'Shutdown', runtime: '26.4', id: 'B' },
  ];
  const result = new DF({ family: 'all', runtime: 'latest', search: '' }).apply(devices);
  assert.deepEqual(result.map((d) => d.id), ['B']);
});

test('apply pinned to an exact runtime keeps only matching devices', () => {
  const DF = DeviceFilter();
  const devices = [
    { name: 'iPhone 17 Pro', state: 'Booted', runtime: '18.4', id: 'A' },
    { name: 'iPhone 17 Pro', state: 'Shutdown', runtime: '26.4', id: 'B' },
  ];
  const result = new DF({ family: 'all', runtime: '18.4', search: '' }).apply(devices);
  assert.deepEqual(result.map((d) => d.id), ['A']);
});

test('apply search term matches across name, state, runtime, and id, case-insensitively', () => {
  const DF = DeviceFilter();
  const devices = [
    { name: 'iPhone 17 Pro', state: 'Booted', runtime: '26.4', id: 'ABC-123' },
    { name: 'iPhone 17 Pro Max', state: 'Shutdown', runtime: '26.4', id: 'DEF-456' },
  ];
  const result = new DF({ family: 'all', runtime: 'all', search: 'def' }).apply(devices);
  assert.deepEqual(result.map((d) => d.id), ['DEF-456']);
});

test('matches combines all three criteria, requiring every one to pass', () => {
  const DF = DeviceFilter();
  const device = { name: 'iPhone 17 Pro', state: 'Booted', runtime: '26.4', id: 'A' };

  assert.equal(new DF({ family: 'iphones', runtime: 'all', search: '' }).matches(device, '26.4'), true);
  assert.equal(new DF({ family: 'ipads', runtime: 'all', search: '' }).matches(device, '26.4'), false);
  assert.equal(new DF({ family: 'iphones', runtime: '18.0', search: '' }).matches(device, '26.4'), false);
  assert.equal(new DF({ family: 'iphones', runtime: 'all', search: 'nope' }).matches(device, '26.4'), false);
});
