import test from 'node:test';
import assert from 'node:assert/strict';
import { pickedChrome, chromeInAddress } from '../../../Sources/Baguette/Resources/Web/device/picked-chrome.js';

// A borrowed chrome rides `?chrome=` into the device's definition route: the
// one the page's address names (a pick the browser wouldn't store), else the
// one remembered for the device, else none.

const devices = { definitionURL: (id, chrome) => '/devices/' + id + '/definition.json' + (chrome ? '?chrome=' + encodeURIComponent(chrome) : '') };
const storage = (picked) => ({ getItem: () => picked });
const refusing = { getItem: () => { throw new Error('storage blocked'); } };

test('should frame a device in the chrome remembered for it', () => {
  assert.equal(pickedChrome('D', { devices, storage: storage('iPhone 17') }), '/devices/D/definition.json?chrome=iPhone%2017');
});

test('should frame a device in the chrome its page\'s address names, when the browser wouldn\'t store the pick', () => {
  assert.equal(pickedChrome('D', { devices, storage: refusing, address: '?handheld=1&chrome=iPhone%20Air' }),
    '/devices/D/definition.json?chrome=iPhone%20Air');
  assert.equal(pickedChrome('D', { devices, storage: storage('iPhone 17'), address: '?chrome=iPhone%20Air' }),
    '/devices/D/definition.json?chrome=iPhone%20Air');
});

test('should ask for the device\'s own definition when nothing is picked', () => {
  assert.equal(pickedChrome('D', { devices, storage: refusing }), '/devices/D/definition.json');
});

test('should frame a device in no chrome when its page\'s address says none, whatever is remembered', () => {
  assert.equal(pickedChrome('D', { devices, storage: storage('iPhone 17'), address: '?chrome=none' }), '/devices/D/definition.json');
});

test('should name no chrome in the address when no frame is picked', () => {
  assert.equal(chromeInAddress(null), 'none');
  assert.equal(chromeInAddress(''), 'none');
  assert.equal(chromeInAddress('MacBook Pro 14'), 'MacBook Pro 14');
});
