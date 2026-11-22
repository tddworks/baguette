import test from 'node:test';
import assert from 'node:assert/strict';
import { Families } from '../../../Sources/Baguette/Resources/Web/families/families.js';

// Each family builds the Device for its kind, with the roles its devices have
// and no others; the page asks Families once and never reads the kind itself.

const listing = (kind, extra = {}) => ({ id: 'D', name: 'Device', state: 'ready', abilities: ['screen'], kind, ...extra });
const simulated = listing({ platform: 'iOS', reality: 'simulated', model: 'iPhone 17' });
const phone = listing({ platform: 'iOS', reality: 'physical', model: 'iPhone 15 Pro', os: 'iOS 26.1' });
const android = listing({ platform: 'android', reality: 'emulated', model: 'Pixel 9' });
const mac = listing({ platform: 'macOS', reality: 'physical', model: 'Studio Display' }, { name: 'Studio Display' });

/** The server's devices, played by the test: where a definition is, and the simulators it lists. */
const devices = {
  definitionURL: (id, chrome) => '/devices/' + id + '/definition.json' + (chrome ? '?chrome=' + encodeURIComponent(chrome) : ''),
  simulators: async () => ({ running: [{ udid: 'D', name: 'iPhone 17', displayRuntime: 'iOS 26.4', state: 'Booted' }], available: [] }),
};
const storage = (picked = {}) => ({ getItem: (key) => picked[key] ?? null });
const device = (l, opts = {}) => Families.device(l, { id: 'D', devices, storage: storage(opts.picked), address: opts.address || '' });

test('should make a simulated device a simulator, framed by its own bezel', () => {
  const sim = device(simulated);
  assert.equal(sim.family, 'simulator');
  assert.equal(sim.frame.definition, undefined);
  assert.equal(sim.frame.chromePicker, undefined);
  assert.equal(sim.badge, undefined);
});

test('should make the device a simulator when the server lists nothing for it', () => {
  assert.equal(device(null).family, 'simulator');
});

test('should frame a phone on the cable in the chrome its user picked, offering the choice when there is none', () => {
  const picked = device(phone, { picked: { 'baguette.twin.chrome.D': 'iPhone 15 Pro' } });
  assert.equal(picked.family, 'phone');
  assert.equal(picked.frame.definition, '/devices/D/definition.json?chrome=iPhone%2015%20Pro');
  assert.equal(device(phone).frame.definition, '/devices/D/definition.json');
  assert.equal(typeof picked.frame.chromePicker.show, 'function');
  assert.equal(picked.badge, true);
});

test('should frame an Android device as a phone is framed, as its own family', () => {
  const droid = device(android);
  assert.equal(droid.family, 'android');
  assert.equal(typeof droid.frame.chromePicker.show, 'function');
  assert.equal(droid.frame.picker, undefined);
});

test('should let a Mac display pick a Mac frame, draw its pointer, and share it only on a share\'s page', () => {
  const display = device(mac);
  assert.equal(display.family, 'mac');
  assert.equal(typeof display.frame.picker.mount, 'function');
  assert.equal(display.frame.chromePicker, undefined);   // its own frames are its pick, not a phone's
  assert.equal(typeof display.pointer.follow, 'function');
  assert.equal(display.share, undefined);
  const shared = device(mac, { address: '?handheld=1&share=D&room=moreSpace' });
  assert.equal(shared.share.id, 'D');
  assert.equal(shared.share.room, 'moreSpace');
  assert.equal(typeof shared.share.follow, 'function');
});

test('should keep a family\'s roles off every other family', () => {
  for (const other of [simulated, phone, android]) assert.equal(device(other, { address: '?share=D' }).share, undefined);
  for (const other of [simulated, phone, android]) assert.equal(device(other).frame.picker, undefined);
  for (const other of [simulated, phone, android]) assert.equal(device(other).pointer, undefined);
});

test('should describe a simulator as the server lists its simulators', async () => {
  assert.deepEqual(await device(simulated).describe(), { name: 'iPhone 17', runtime: 'iOS 26.4', state: 'Booted' });
});

test('should describe any other device by its own listing', async () => {
  assert.deepEqual(await device(phone).describe(), { name: 'Device', runtime: 'iOS 26.1', state: 'Booted' });
  assert.deepEqual(await device(mac).describe(), { name: 'Studio Display', runtime: 'Studio Display', state: 'Booted' });
});

test('should describe a device as it is listed now, not as it was when the page opened', async () => {
  const fresh = { ...devices, listing: async () => ({ ...phone, state: 'unavailable' }) };
  const now = Families.device(phone, { id: 'D', devices: fresh, storage: storage() });
  assert.equal((await now.describe()).state, 'Shutdown');
});

test('should answer what the device can do from the abilities it is listed with', () => {
  assert.equal(device(mac).can('screen'), true);
  assert.equal(device(mac).can('orientation'), false);
});

test('should allow everything when the server lists nothing for the device, as the toolbar does', () => {
  assert.equal(device(null).can('screen'), true);
  assert.equal(device(null).can('network'), true);
});

test('should boot a simulator through the server\'s devices', async () => {
  const booted = [];
  const booting = { ...devices, boot: async (id) => { booted.push(id); return { ok: false, error: 'already booted' }; } };
  const sim = Families.device(simulated, { id: 'D', devices: booting, storage: storage() });
  assert.deepEqual(await sim.power.boot(), { ok: false, error: 'already booted' });
  assert.deepEqual(booted, ['D']);
});

test('should boot an Android device only when the server lists it as one that can', () => {
  assert.equal(typeof device({ ...android, abilities: ['screen', 'power'] }).power.boot, 'function');
  assert.equal(device(android).power, undefined);
});

test('should give a phone on the cable and a Mac display no power to boot', () => {
  assert.equal(device(phone).power, undefined);
  assert.equal(device(mac).power, undefined);
});

test('should turn a simulator\'s input back to portrait, and give no other family an orientation', () => {
  const turned = device(simulated).orientation.toPortrait({ type: 'tap', x: 0, y: 0, width: 10, height: 10 }, 'portrait-upside-down');
  assert.deepEqual([turned.x, turned.y], [10, 10]);
  for (const other of [phone, android, mac]) assert.equal(device(other).orientation, undefined);
});

test('should give a simulator its companion screens, and no other family any', () => {
  assert.equal(typeof device(simulated).companions.mount, 'function');
  for (const other of [phone, android, mac]) assert.equal(device(other).companions, undefined);
});

test('should turn a simulator through the server, a quarter clockwise each step of its cycle', async () => {
  const turned = [];
  const sim = Families.device(simulated, { id: 'D', devices: { ...devices, turn: async (id, value) => turned.push([id, value]) }, storage: storage() });
  assert.deepEqual(sim.orientation.cycle, ['portrait', 'landscape-left', 'portrait-upside-down', 'landscape-right']);
  await sim.orientation.turn('landscape-left');
  assert.deepEqual(turned, [['D', 'landscape-left']]);
});
