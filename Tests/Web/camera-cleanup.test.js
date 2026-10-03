'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const { CameraPanel } = loadBrowserModule(path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web', 'sim-camera.js'
));

test('failed cleanup offers an explicit stop retry and cannot start another source', () => {
  const panel = new CameraPanel();
  const sent = [];
  const status = { style: {} };
  const toggle = {};
  panel.host = { querySelector: (selector) => selector === '[data-camera-status]' ? status : toggle };
  panel.selectedUID = 'camera';
  panel._send = (message) => sent.push(JSON.parse(JSON.stringify(message)));
  panel._onMessage({ data: JSON.stringify({
    type: 'camera_state', phase: 'idle', ok: false,
    cleanupRequired: true, error: 'disarm denied',
  }) });
  assert.equal(toggle.textContent, 'Retry stop');
  assert.equal(status.textContent, 'disarm denied');
  panel._startCurrent();
  assert.deepEqual(sent, []);
  panel._onToggle();
  assert.deepEqual(sent, [{ type: 'camera_stop' }]);

  panel._onMessage({ data: JSON.stringify({
    type: 'camera_state', phase: 'idle', ok: true, cleanupRequired: false,
  }) });
  assert.equal(toggle.textContent, 'Start');
  panel._onToggle();
  assert.equal(sent[1].type, 'camera_start');
});
