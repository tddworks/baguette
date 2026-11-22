import test from 'node:test';
import assert from 'node:assert/strict';
import { DeviceFilter } from '../../../Sources/Baguette/Resources/Web/page/internal/device-filter.js';

// The devices of every family, as `/devices.json` lists them.
const SIMULATOR = { id: 'S', name: 'iPhone 17 Pro', platform: 'iOS', reality: 'simulated', model: 'iPhone 17 Pro', os: 'iOS 26.4', state: 'ready' };
const OLD_SIMULATOR = { id: 'O', name: 'iPhone 15', platform: 'iOS', reality: 'simulated', model: 'iPhone 15', os: 'iOS 18.2', state: 'off' };
const PHONE = { id: 'P', name: 'han’s iPhone', platform: 'iOS', reality: 'physical', model: 'iPhone 18 Pro Max', os: 'iOS 27.0.1', state: 'ready' };
const EMULATOR = { id: 'baguette_pixel', name: 'sdk gphone64 arm64', platform: 'android', reality: 'emulated', model: 'sdk_gphone64_arm64', state: 'ready' };
const ALL = [SIMULATOR, OLD_SIMULATOR, PHONE, EMULATOR];

function filter(criteria) {
  const DF = DeviceFilter;
  return new DF({ platform: 'all', reality: 'all', os: 'all', search: '', ...criteria });
}

test('should order dotted numeric versions ascending', () => {
  const { compareVersions } = DeviceFilter;
  assert.ok(compareVersions('iOS 18.2', 'iOS 18.4') < 0);
  assert.ok(compareVersions('iOS 18.4', 'iOS 18.2') > 0);
  assert.equal(compareVersions('iOS 18.4', 'iOS 18.4'), 0);
});

test('should rank an OS with no digits below any real version', () => {
  const { compareVersions } = DeviceFilter;
  assert.ok(compareVersions('', '18.0') < 0);
  assert.ok(compareVersions('nightly', '1.0') < 0);
});

test('should keep every device of every family when nothing is chosen', () => {
  assert.deepEqual(filter({}).apply(ALL).map((d) => d.id), ['S', 'O', 'P', 'baguette_pixel']);
});

test('should keep only Android devices when the Android platform is chosen', () => {
  assert.deepEqual(filter({ platform: 'android' }).apply(ALL).map((d) => d.id), ['baguette_pixel']);
});

test('should keep only iOS devices, real and simulated, when the iOS platform is chosen', () => {
  assert.deepEqual(filter({ platform: 'iOS' }).apply(ALL).map((d) => d.id), ['S', 'O', 'P']);
});

test('should keep only real devices when real is chosen', () => {
  assert.deepEqual(filter({ reality: 'real' }).apply(ALL).map((d) => d.id), ['P']);
});

test('should keep simulators and emulators alike when virtual is chosen', () => {
  assert.deepEqual(filter({ reality: 'virtual' }).apply(ALL).map((d) => d.id), ['S', 'O', 'baguette_pixel']);
});

test('should keep the newest OS of each kind of device, and devices that name none, when latest is chosen', () => {
  assert.deepEqual(filter({ os: 'latest' }).apply(ALL).map((d) => d.id), ['S', 'P', 'baguette_pixel']);
});

test('should keep only devices on an OS when it is pinned exactly', () => {
  assert.deepEqual(filter({ os: 'iOS 18.2' }).apply(ALL).map((d) => d.id), ['O']);
});

test('should find devices by name, model, OS or id, case-insensitively', () => {
  assert.deepEqual(filter({ search: 'GPHONE' }).apply(ALL).map((d) => d.id), ['baguette_pixel']);
  assert.deepEqual(filter({ search: '18.2' }).apply(ALL).map((d) => d.id), ['O']);
  assert.deepEqual(filter({ search: 'pixel' }).apply(ALL).map((d) => d.id), ['baguette_pixel']);
});

test('should keep only devices that pass every criterion', () => {
  assert.deepEqual(filter({ platform: 'iOS', reality: 'virtual', search: '15' }).apply(ALL).map((d) => d.id), ['O']);
});

test('should list each OS the devices name, newest first per platform', () => {
  const { osNames } = DeviceFilter;
  assert.deepEqual(osNames(ALL), ['iOS 27.0.1', 'iOS 26.4', 'iOS 18.2']);
});
