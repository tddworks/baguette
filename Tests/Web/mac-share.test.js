'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web', 'mac-share.js'
);

function MacShare() {
  return loadBrowserModule(MODULE_PATH).Baguette._MacShare;
}

const iPhone = 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15';

test('should ask for a display of the visible screen, at its pixel ratio, room and use', () => {
  const body = MacShare().request({
    viewport: { width: 402, height: 874 }, pixelRatio: 3, userAgent: iPhone, room: 'moreSpace', use: 'main',
  });
  assert.deepEqual(body, { viewer: 'iPhone', width: 402, height: 874, scale: 3, room: 'moreSpace', use: 'main' });
});

test('should name the viewer by the kind of device it is', () => {
  const name = (ua) => MacShare().request({ viewport: { width: 1, height: 1 }, pixelRatio: 1, userAgent: ua }).viewer;
  assert.equal(name('Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X)'), 'iPad');
  assert.equal(name('Mozilla/5.0 (Linux; Android 15; Pixel 9)'), 'Android');
  assert.equal(name('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)'), 'Mac');
  assert.equal(name('Mozilla/5.0 (Windows NT 10.0)'), 'browser');
});

test('should round a fractional viewport down to whole points', () => {
  const body = MacShare().request({ viewport: { width: 402.6, height: 873.9 }, pixelRatio: 3, userAgent: iPhone });
  assert.equal(body.width, 402);
  assert.equal(body.height, 873);
});

test('should open the shared display in the hand, remembering which share it is', () => {
  assert.equal(MacShare().pageAddress('454C-UUID'), '/devices/454C-UUID?handheld=1&share=454C-UUID');
});

test('should remember the room asked for, so a turn keeps it', () => {
  assert.equal(MacShare().pageAddress('454C-UUID', 'moreSpace'),
    '/devices/454C-UUID?handheld=1&share=454C-UUID&room=moreSpace');
});

test('should carry the codec asked for on the share page to the shared display', () => {
  assert.equal(MacShare().pageAddress('454C-UUID', 'moreSpace', 'h265'),
    '/devices/454C-UUID?handheld=1&share=454C-UUID&room=moreSpace&codec=h265');
  assert.equal(MacShare().pageAddress('454C-UUID', '', 'h265'), '/devices/454C-UUID?handheld=1&share=454C-UUID&codec=h265');
});

test('should read the share a page shows, and its room, from its address', () => {
  assert.deepEqual(MacShare().fromAddress('?handheld=1&share=454C-UUID&room=moreSpace'),
    { id: '454C-UUID', room: 'moreSpace' });
  assert.equal(MacShare().fromAddress('?handheld=1'), null);
});

test('should remake the display when the viewer turns', () => {
  assert.equal(MacShare().turned({ width: 402, height: 874 }, { width: 874, height: 402 }), true);
});

test('should leave the display be when the size only wobbles, as a browser bar comes and goes', () => {
  assert.equal(MacShare().turned({ width: 402, height: 874 }, { width: 402, height: 830 }), false);
});

test('should remake the display when the viewer is resized a good deal without turning', () => {
  assert.equal(MacShare().turned({ width: 800, height: 600 }, { width: 1200, height: 900 }), true);
});

test('should show a shared Mac over WebRTC unless the tab picked another format', () => {
  assert.equal(MacShare().format(null), 'webrtc');
  assert.equal(MacShare().format('avcc'), 'avcc');
});
