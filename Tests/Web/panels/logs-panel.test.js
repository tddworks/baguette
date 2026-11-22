import test from 'node:test';
import assert from 'node:assert/strict';
import { logsPanel, logsPanelWith } from '../../../Sources/Baguette/Resources/Web/panels/logs/logs-panel.js';

// The logs panel: the device's unified log, live, from info up.

test('should need the device\'s logs, and sit in the page\'s logs sheet', () => {
  assert.equal(logsPanel.name, 'logs');
  assert.equal(logsPanel.needs, 'logs');
  assert.equal(logsPanel.slot, 'Logs');
});

test('should show the device\'s log from info up when it opens', () => {
  const made = [];
  const host = {};
  logsPanelWith(class { constructor(h, options) { made.push({ host: h, options }); } }).mount(host, { device: { id: 'D' } });
  assert.deepEqual(made, [{ host, options: { udid: 'D', level: 'info' } }]);
});
