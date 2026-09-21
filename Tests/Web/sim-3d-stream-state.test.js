'use strict';

// What the live 3D stage says when its socket ends before a frame lands.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModules } = require('./helpers/load-browser-module.js');

const WEB = path.join(__dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web');

function fakeStage() {
  const label = { textContent: '' };
  const spinner = { hidden: false };
  const state = {
    hidden: true,
    error: false,
    toggleAttribute(name, on) { if (name === 'data-error') this.error = on; },
    querySelector: (sel) => (sel === '.r3d-spinner' ? spinner : label),
  };
  return {
    label,
    state,
    querySelector: (sel) => (sel === '[data-role="live-state"]' ? state : null),
    getBoundingClientRect: () => ({ width: 960, height: 960 }),
  };
}

function startedPanel(t) {
  const saved = { location: global.location, document: global.document };
  global.location = { protocol: 'http:', host: 'localhost:8421' };
  global.document = { addEventListener() {}, removeEventListener() {} };
  t.after(() => Object.assign(global, saved));
  const window = loadBrowserModules([path.join(WEB, 'sim-3d.js')]);
  let session = null;
  window.StreamSession = function (opts) { this.opts = opts; session = this; };
  window.StreamSession.prototype.start = function () {};
  window.StreamSession.prototype.stop = function () {};
  const panel = new window.Sim3DPanel();
  const stage = fakeStage();
  panel.udid = 'DUO';
  panel.model = { id: 'iphone-duo' };
  panel.stage = stage;
  panel.canvas = { hasAttribute: () => false, setAttribute() {} };
  panel.start();
  return { opts: session.opts, stage };
}

test('a refusal the server explains outlives the close that follows it', (t) => {
  const { opts, stage } = startedPanel(t);
  opts.onText({ ok: false, error: 'localAssetNotFound("V68.usdz")' });
  opts.onClose();
  assert.equal(stage.label.textContent, 'localAssetNotFound("V68.usdz")');
  assert.equal(stage.state.error, true);
});

test('a socket that drops without a word says it disconnected', (t) => {
  const { opts, stage } = startedPanel(t);
  opts.onClose();
  assert.equal(stage.label.textContent, '3D stream disconnected');
});
