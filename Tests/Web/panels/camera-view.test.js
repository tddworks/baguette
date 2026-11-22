import test from 'node:test';
import assert from 'node:assert/strict';
import { CameraPanel } from '../../../Sources/Baguette/Resources/Web/panels/camera/internal/camera-view.js';


test('should offer a stop retry and start no other source when cleanup failed', () => {
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
