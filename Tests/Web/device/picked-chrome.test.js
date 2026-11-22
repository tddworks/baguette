import test from 'node:test';
import assert from 'node:assert/strict';
import { pickedChrome } from '../../../Sources/Baguette/Resources/Web/device/picked-chrome.js';

// A borrowed chrome rides `?chrome=` into the device's definition route: the
// one the page's address names (a pick the browser wouldn't store), else the
// one remembered for the device, else none.

const wire = { path: (id, suffix) => '/devices/' + id + suffix };
const storage = (picked) => ({ getItem: () => picked });
const refusing = { getItem: () => { throw new Error('storage blocked'); } };

test('should frame a device in the chrome remembered for it', () => {
  assert.equal(pickedChrome('D', { wire, storage: storage('iPhone 17') }), '/devices/D/definition.json?chrome=iPhone%2017');
});

test('should frame a device in the chrome its page\'s address names, when the browser wouldn\'t store the pick', () => {
  assert.equal(pickedChrome('D', { wire, storage: refusing, address: '?handheld=1&chrome=iPhone%20Air' }),
    '/devices/D/definition.json?chrome=iPhone%20Air');
  assert.equal(pickedChrome('D', { wire, storage: storage('iPhone 17'), address: '?chrome=iPhone%20Air' }),
    '/devices/D/definition.json?chrome=iPhone%20Air');
});

test('should ask for the device\'s own definition when nothing is picked', () => {
  assert.equal(pickedChrome('D', { wire, storage: refusing }), '/devices/D/definition.json');
});
