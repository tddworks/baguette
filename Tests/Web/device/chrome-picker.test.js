import test from 'node:test';
import assert from 'node:assert/strict';
import { chromeChoices } from '../../../Sources/Baguette/Resources/Web/device/chrome-picker.js';

// A device with no bezel of its own borrows a phone's or tablet's chrome:
// the current iPhones, then every simulator model installed, each once.

test('should offer the current iPhones first, then each installed phone or tablet once', () => {
  const listed = { running: [{ name: 'iPhone 17 Pro' }], available: [{ name: 'iPad Pro 13-inch (M5)' }, { name: 'iPhone 15' }] };
  assert.deepEqual(chromeChoices(listed),
    ['iPhone 17 Pro', 'iPhone 17 Pro Max', 'iPhone 17', 'iPhone Air', 'iPad Pro 13-inch (M5)', 'iPhone 15']);
});

test('should offer no watch or TV, whose bezel can\'t frame a phone\'s screen', () => {
  const listed = { running: [], available: [{ name: 'Apple Watch Series 11 (46mm)' }, { name: 'Apple TV 4K' }] };
  assert.deepEqual(chromeChoices(listed), ['iPhone 17 Pro', 'iPhone 17 Pro Max', 'iPhone 17', 'iPhone Air']);
});

test('should still offer the current iPhones when the simulators can\'t be listed', () => {
  assert.equal(chromeChoices(null).length, 4);
});
