import test from 'node:test';
import assert from 'node:assert/strict';
import { pageStorage } from '../../../Sources/Baguette/Resources/Web/device/page-storage.js';

// A browser may refuse a page its storage outright (reading `localStorage`
// throws): the page still loads, and simply remembers nothing.

test('should use the browser\'s storage when it gives one', () => {
  const local = { getItem: () => 'x' };
  assert.equal(pageStorage({ get localStorage() { return local; } }), local);
});

test('should remember nothing, without throwing, when the browser refuses its storage', () => {
  const storage = pageStorage({ get localStorage() { throw new Error('SecurityError'); } });
  assert.equal(storage.getItem('k'), null);
  assert.doesNotThrow(() => { storage.setItem('k', 'v'); storage.removeItem('k'); });
  assert.equal(storage.getItem('k'), null);
});
