'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModules } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'stream-session.js'
);

function loadStreamSession(seed) {
  const window = Object.assign({
    location: { protocol: 'http:', host: 'localhost:8421' },
  }, seed || {});
  return loadBrowserModules([MODULE_PATH], window);
}

test('buildWSUrl omits display when not requested', () => {
  const { StreamSession } = loadStreamSession();
  const url = StreamSession.buildWSUrl('UDID-1', 'mjpeg', 'v2');
  assert.equal(
    url,
    'ws://localhost:8421/simulators/UDID-1/stream?format=mjpeg&version=v2'
  );
});

test('buildWSUrl appends display=carplay when requested', () => {
  const { StreamSession } = loadStreamSession();
  const url = StreamSession.buildWSUrl('UDID-1', 'mjpeg', 'v2', 'carplay');
  assert.equal(
    url,
    'ws://localhost:8421/simulators/UDID-1/stream?format=mjpeg&version=v2&display=carplay'
  );
});

test('buildWSUrl appends display=phone when requested', () => {
  const { StreamSession } = loadStreamSession();
  const url = StreamSession.buildWSUrl('UDID-1', 'avcc', 'v2', 'phone');
  assert.equal(
    url,
    'ws://localhost:8421/simulators/UDID-1/stream?format=avcc&version=v2&display=phone'
  );
});

test('buildWSUrl encodes udid and ignores unknown display tokens', () => {
  const { StreamSession } = loadStreamSession();
  const url = StreamSession.buildWSUrl('a/b', 'mjpeg', 'v2', 'external');
  assert.equal(
    url,
    'ws://localhost:8421/simulators/a%2Fb/stream?format=mjpeg&version=v2'
  );
});

test('visibleSize shows the screen part of a frame an encoder padded', () => {
  const { StreamSession } = loadStreamSession();
  assert.deepEqual(
    StreamSession.visibleSize(1328, 2896, { width: 1320, height: 2868 }),
    { width: 1320, height: 2868 });
});

test('visibleSize turns the screen with a landscape frame', () => {
  const { StreamSession } = loadStreamSession();
  assert.deepEqual(
    StreamSession.visibleSize(2896, 1328, { width: 1320, height: 2868 }),
    { width: 2868, height: 1320 });
});

test('visibleSize keeps a frame that is already the screen, or has no screen size', () => {
  const { StreamSession } = loadStreamSession();
  assert.deepEqual(StreamSession.visibleSize(1320, 2868, { width: 1320, height: 2868 }), { width: 1320, height: 2868 });
  assert.deepEqual(StreamSession.visibleSize(1328, 2896, null), { width: 1328, height: 2896 });
});

test('visibleSize never asks for more than the frame has', () => {
  const { StreamSession } = loadStreamSession();
  assert.deepEqual(
    StreamSession.visibleSize(660, 1434, { width: 1320, height: 2868 }),
    { width: 660, height: 1434 });
});
