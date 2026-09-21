'use strict';

// Baguette.use with a definition in hand skips the fetch (a foldable's other panel).

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModules } = require('./helpers/load-browser-module.js');

const WEB = path.join(__dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web');

function loadSDK(t) {
  const saved = global.fetch;
  const fetched = [];
  global.fetch = async (url) => {
    fetched.push(url);
    return { ok: true, json: async () => ({ identity: {}, screen: { from: 'network' } }) };
  };
  t.after(() => { global.fetch = saved; });
  const window = loadBrowserModules([path.join(WEB, 'baguette', 'baguette.js')]);
  window.Baguette._Transport = function () {};
  window.Baguette._Simulator = function (def) { this.def = def; };
  return { Baguette: window.Baguette, fetched };
}

test('a definition in hand builds the simulator without fetching', async (t) => {
  const { Baguette, fetched } = loadSDK(t);
  const definition = { identity: {}, screen: { from: 'cache' } };
  const sim = await Baguette.use({ host: 'http://h', udid: 'DUO', send() {}, definition });
  assert.deepEqual(fetched, []);
  assert.equal(sim.def, definition);
});

test('without one it fetches the definition route', async (t) => {
  const { Baguette, fetched } = loadSDK(t);
  const sim = await Baguette.use({ host: 'http://h', udid: 'DUO', send() {} });
  assert.deepEqual(fetched, ['http://h/simulators/DUO/definition.json']);
  assert.equal(sim.def.screen.from, 'network');
});
