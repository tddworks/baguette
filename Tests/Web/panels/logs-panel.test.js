import test from 'node:test';
import assert from 'node:assert/strict';
import { logsPanel } from '../../../Sources/Baguette/Resources/Web/panels/logs/logs-panel.js';

// The logs panel: the device's unified log, live, from info up.

test('should need the device\'s logs, and sit in the page\'s logs sheet', () => {
  assert.equal(logsPanel.name, 'logs');
  assert.equal(logsPanel.needs, 'logs');
  assert.equal(logsPanel.slot, 'Logs');
});

test('should show the device\'s log from info up when it opens', () => {
  const saved = globalThis.window;
  const made = [];
  globalThis.window = { LogPanel: class { constructor(host, options) { made.push({ host, options }); } } };
  try {
    const host = {};
    logsPanel.mount(host, { device: { id: 'D' } });
    assert.deepEqual(made, [{ host, options: { udid: 'D', level: 'info' } }]);
  } finally {
    globalThis.window = saved;
  }
});
