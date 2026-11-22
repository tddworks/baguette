import test from 'node:test';
import assert from 'node:assert/strict';
import { StreamSession } from '../../../Sources/Baguette/Resources/Web/stream/stream-session.js';

// The module reads the browser off the global `window` when it runs;
// each test installs its own and the original comes back after.
const realWindow = globalThis.window;
test.afterEach(() => { globalThis.window = realWindow; });

function loadStreamSession(seed) {
  globalThis.window = Object.assign({
    location: { protocol: 'http:', host: 'localhost:8421' },
  }, seed || {});
  return { StreamSession };
}

test('should name no display plane when none is asked for', () => {
  const { StreamSession } = loadStreamSession();
  const url = StreamSession.buildWSUrl('UDID-1', 'mjpeg', 'v2');
  assert.equal(
    url,
    'ws://localhost:8421/devices/UDID-1/stream?format=mjpeg&version=v2'
  );
});

test('should ask for the CarPlay plane when asked for', () => {
  const { StreamSession } = loadStreamSession();
  const url = StreamSession.buildWSUrl('UDID-1', 'mjpeg', 'v2', 'carplay');
  assert.equal(
    url,
    'ws://localhost:8421/devices/UDID-1/stream?format=mjpeg&version=v2&display=carplay'
  );
});

test('should ask for the phone plane when asked for', () => {
  const { StreamSession } = loadStreamSession();
  const url = StreamSession.buildWSUrl('UDID-1', 'avcc', 'v2', 'phone');
  assert.equal(
    url,
    'ws://localhost:8421/devices/UDID-1/stream?format=avcc&version=v2&display=phone'
  );
});

test('should escape the udid and ignore an unknown display', () => {
  const { StreamSession } = loadStreamSession();
  const url = StreamSession.buildWSUrl('a/b', 'mjpeg', 'v2', 'external');
  assert.equal(
    url,
    'ws://localhost:8421/devices/a%2Fb/stream?format=mjpeg&version=v2'
  );
});
