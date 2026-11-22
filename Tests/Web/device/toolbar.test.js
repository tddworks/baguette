import test from 'node:test';
import assert from 'node:assert/strict';
import { toolbarFor } from '../../../Sources/Baguette/Resources/Web/device/toolbar.js';

// The toolbar a device gets: its actions and its panels' controls, each only
// when the device has the ability it needs; a panel places its own control.

const clusters = [
  { id: 'control', members: [{ id: 'nativeRotate', label: 'Rotate', role: 'action', needs: 'orientation' },
                             { id: 'nativeHome', label: 'Home', role: 'action', needs: 'press' }] },
  { id: 'simulate', members: [] },
  { id: 'inspect', members: [{ id: 'nativeAxToggle', label: 'Accessibility', role: 'state', needs: 'accessibility' }] },
  { id: 'capture', members: [{ id: 'nativeScreenshot', label: 'Screenshot', role: 'action' }] },
];
const panel = (name, slot, cluster, needs) => ({ name, slot, cluster, label: name, needs });
const panels = [panel('location', 'Location', 'simulate', 'location'), panel('network', 'Network', 'simulate', 'network'),
                panel('logs', 'Logs', 'inspect', 'logs')];
const ids = (toolbar) => toolbar.clusters.map((c) => [c.id, c.members.map((m) => m.id)]);

test('should place each panel\'s control in the cluster it names, after the cluster\'s own', () => {
  const toolbar = toolbarFor(clusters, { panels, abilities: ['orientation', 'press', 'location', 'network', 'logs', 'accessibility'] });
  assert.deepEqual(ids(toolbar), [
    ['control', ['nativeRotate', 'nativeHome']],
    ['simulate', ['nativeLocationToggle', 'nativeNetworkToggle']],
    ['inspect', ['nativeAxToggle', 'nativeLogsToggle']],
    ['capture', ['nativeScreenshot']],
  ]);
  assert.deepEqual(toolbar.hidden, []);
});

test('should leave out what the device can\'t do, and a cluster left empty, saying which controls go', () => {
  const toolbar = toolbarFor(clusters, { panels, abilities: ['logs'] });
  assert.deepEqual(ids(toolbar), [['inspect', ['nativeLogsToggle']], ['capture', ['nativeScreenshot']]]);
  assert.deepEqual(toolbar.hidden.sort(), ['nativeAxToggle', 'nativeHome', 'nativeLocationToggle', 'nativeNetworkToggle', 'nativeRotate']);
});

test('should show every control when the server lists no abilities for the device', () => {
  const toolbar = toolbarFor(clusters, { panels, abilities: null });
  assert.equal(toolbar.clusters.flatMap((c) => c.members).length, 7);
  assert.deepEqual(toolbar.hidden, []);
});

test('should leave the clusters it was given as they were', () => {
  toolbarFor(clusters, { panels, abilities: [] });
  assert.equal(clusters[0].members.length, 2);
  assert.equal(clusters[1].members.length, 0);
});
