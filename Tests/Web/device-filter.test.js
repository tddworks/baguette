'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'page', 'internal', 'device-filter.js'
);

function DeviceFilter() {
  return loadBrowserModule(MODULE_PATH).Baguette._DeviceFilter;
}

// The devices of every family, as `/devices.json` lists them.
const SIMULATOR = { id: 'S', name: 'iPhone 17 Pro', platform: 'iOS', reality: 'simulated', model: 'iPhone 17 Pro', os: 'iOS 26.4', state: 'ready' };
const OLD_SIMULATOR = { id: 'O', name: 'iPhone 15', platform: 'iOS', reality: 'simulated', model: 'iPhone 15', os: 'iOS 18.2', state: 'off' };
const PHONE = { id: 'P', name: 'han’s iPhone', platform: 'iOS', reality: 'physical', model: 'iPhone 18 Pro Max', os: 'iOS 27.0.1', state: 'ready' };
const EMULATOR = { id: 'baguette_pixel', name: 'sdk gphone64 arm64', platform: 'android', reality: 'emulated', model: 'sdk_gphone64_arm64', state: 'ready' };
const ALL = [SIMULATOR, OLD_SIMULATOR, PHONE, EMULATOR];

function filter(criteria) {
  const DF = DeviceFilter();
  return new DF({ platform: 'all', reality: 'all', os: 'all', search: '', ...criteria });
}

test('compareVersions orders dotted numeric versions ascending', () => {
  const { compareVersions } = DeviceFilter();
  assert.ok(compareVersions('iOS 18.2', 'iOS 18.4') < 0);
  assert.ok(compareVersions('iOS 18.4', 'iOS 18.2') > 0);
  assert.equal(compareVersions('iOS 18.4', 'iOS 18.4'), 0);
});

test('compareVersions treats an OS with no digits as lower than any real version', () => {
  const { compareVersions } = DeviceFilter();
  assert.ok(compareVersions('', '18.0') < 0);
  assert.ok(compareVersions('nightly', '1.0') < 0);
});

test('keeps every device of every family when nothing is chosen', () => {
  assert.deepEqual(filter({}).apply(ALL).map((d) => d.id), ['S', 'O', 'P', 'baguette_pixel']);
});

test('keeps only Android devices for the Android platform', () => {
  assert.deepEqual(filter({ platform: 'android' }).apply(ALL).map((d) => d.id), ['baguette_pixel']);
});

test('keeps only iOS devices, real and simulated, for the iOS platform', () => {
  assert.deepEqual(filter({ platform: 'iOS' }).apply(ALL).map((d) => d.id), ['S', 'O', 'P']);
});

test('keeps only real devices when real is chosen', () => {
  assert.deepEqual(filter({ reality: 'real' }).apply(ALL).map((d) => d.id), ['P']);
});

test('keeps simulators and emulators alike when virtual is chosen', () => {
  assert.deepEqual(filter({ reality: 'virtual' }).apply(ALL).map((d) => d.id), ['S', 'O', 'baguette_pixel']);
});

test('keeps the newest OS of each kind of device when latest is chosen, and devices that name none', () => {
  assert.deepEqual(filter({ os: 'latest' }).apply(ALL).map((d) => d.id), ['S', 'P', 'baguette_pixel']);
});

test('keeps only devices on an OS pinned exactly', () => {
  assert.deepEqual(filter({ os: 'iOS 18.2' }).apply(ALL).map((d) => d.id), ['O']);
});

test('finds devices by name, model, OS or id, case-insensitively', () => {
  assert.deepEqual(filter({ search: 'GPHONE' }).apply(ALL).map((d) => d.id), ['baguette_pixel']);
  assert.deepEqual(filter({ search: '18.2' }).apply(ALL).map((d) => d.id), ['O']);
  assert.deepEqual(filter({ search: 'pixel' }).apply(ALL).map((d) => d.id), ['baguette_pixel']);
});

test('requires every criterion to pass', () => {
  assert.deepEqual(filter({ platform: 'iOS', reality: 'virtual', search: '15' }).apply(ALL).map((d) => d.id), ['O']);
});

test('lists each OS the devices name, newest first per platform', () => {
  const { osNames } = DeviceFilter();
  assert.deepEqual(osNames(ALL), ['iOS 27.0.1', 'iOS 26.4', 'iOS 18.2']);
});
