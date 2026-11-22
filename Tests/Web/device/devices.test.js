import test from 'node:test';
import assert from 'node:assert/strict';
import { serverDevices } from '../../../Sources/Baguette/Resources/Web/device/devices.js';

// This server's devices, as the page asks about them — Swift's Devices,
// over its routes: a device's listing and definition, booting it, the
// simulators it lists, and the Mac frames that fit a size.

function server(answers = {}) {
  const asked = [];
  const fetch = async (url, init = {}) => {
    asked.push((init.method || 'GET') + ' ' + url);
    const answer = answers[url] ?? { ok: true, status: 200, body: {} };
    return { ok: answer.ok, status: answer.status, json: async () => answer.body };
  };
  return { asked, devices: serverDevices(fetch) };
}

test('should read a device\'s listing, or nothing when the server has none', async () => {
  const { asked, devices } = server({ '/devices/D/device.json': { ok: true, body: { id: 'D' } },
                                      '/devices/X/device.json': { ok: false, status: 404 } });
  assert.deepEqual(await devices.listing('D'), { id: 'D' });
  assert.equal(await devices.listing('X'), null);
  assert.deepEqual(asked, ['GET /devices/D/device.json', 'GET /devices/X/device.json']);
});

test('should name a device\'s definition, in a borrowed chrome when one is picked', () => {
  const { devices } = server();
  assert.equal(devices.definitionURL('D'), '/devices/D/definition.json');
  assert.equal(devices.definitionURL('A B', 'iPhone Air'), '/devices/A%20B/definition.json?chrome=iPhone%20Air');
});

test('should boot a device, saying why when the server refuses', async () => {
  const { asked, devices } = server({ '/devices/D/boot': { ok: false, status: 409, body: { error: 'already booted' } } });
  assert.deepEqual(await devices.boot('D'), { ok: false, error: 'already booted' });
  assert.deepEqual(asked, ['POST /devices/D/boot']);
});

test('should list the simulators, and the Mac frames that fit a size', async () => {
  const { asked, devices } = server({ '/simulators.json': { ok: true, body: { running: [] } },
                                      '/mac-frames.json?width=2560&height=1440': { ok: true, body: { frames: ['iMac'] } } });
  assert.deepEqual(await devices.simulators(), { running: [] });
  assert.deepEqual(await devices.framesFitting(2560, 1440), ['iMac']);
  assert.deepEqual(asked, ['GET /simulators.json', 'GET /mac-frames.json?width=2560&height=1440']);
});

test('should read a device\'s definition', async () => {
  const { devices } = server({ '/devices/D/definition.json': { ok: true, body: { screen: { rect: { width: 1 } } } } });
  assert.deepEqual(await devices.definition('D'), { screen: { rect: { width: 1 } } });
});
