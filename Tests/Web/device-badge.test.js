'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web', 'device', 'device-badge.js'
);

function DeviceBadge() {
  return loadBrowserModule(MODULE_PATH).Baguette._DeviceBadge;
}

test('should call a device that takes touches touchable', () => {
  const badge = DeviceBadge().of(['screen', 'touch', 'pasteboard']);
  assert.equal(badge.text, 'DEVICE · touch');
});

test('should call a device without input view-only', () => {
  const badge = DeviceBadge().of(['screen']);
  assert.equal(badge.text, 'DEVICE · view-only');
});

test('should name what a device can do in its title', () => {
  const badge = DeviceBadge().of(['screen', 'touch']);
  assert.match(badge.title, /screen, touch/);
});

test('should read a device with no abilities listed as view-only', () => {
  assert.equal(DeviceBadge().of(undefined).text, 'DEVICE · view-only');
});


