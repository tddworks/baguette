import test from 'node:test';
import assert from 'node:assert/strict';
import { cameraPanel } from '../../../Sources/Baguette/Resources/Web/panels/camera/camera-panel.js';
import { statusBarPanel } from '../../../Sources/Baguette/Resources/Web/panels/status-bar/status-bar-panel.js';
import { networkPanel } from '../../../Sources/Baguette/Resources/Web/panels/network/network-panel.js';
import { notifyPanel } from '../../../Sources/Baguette/Resources/Web/panels/notify/notify-panel.js';
import { defaultsPanel } from '../../../Sources/Baguette/Resources/Web/panels/defaults/defaults-panel.js';
import { locationPanel } from '../../../Sources/Baguette/Resources/Web/panels/location/location-panel.js';

// The page's sheet panels: each needs its ability, sits in its sheet, and
// mounts its view on the device; some say more on their control.

/** A view class, recording how it was attached and told. */
function viewClass(calls) {
  return class {
    attach(host, udid) { calls.push(['attach', host, udid]); }
    refresh() { calls.push(['refresh']); }
    detach() { calls.push(['detach']); }
  };
}

function control() {
  const classes = new Set(), attributes = {};
  return {
    classes, attributes,
    classList: { toggle: (c, on) => (on ? classes.add(c) : classes.delete(c)) },
    setAttribute: (k, v) => { attributes[k] = v; },
  };
}

/** Run `body` with `window` holding `globals`. */
async function withWindow(globals, body) {
  const saved = { window: globalThis.window, fetch: globalThis.fetch };
  globalThis.window = { ...globals };
  try { return await body(); } finally { globalThis.window = saved.window; globalThis.fetch = saved.fetch; }
}

const each = [
  [cameraPanel, 'camera', 'camera', 'Camera', 'CameraPanel'],
  [statusBarPanel, 'statusBar', 'statusBar', 'StatusBar', 'StatusBarPanel'],
  [networkPanel, 'network', 'network', 'Network', 'NetworkPanel'],
  [notifyPanel, 'notify', 'notify', 'Notify', 'NotifyPanel'],
  [defaultsPanel, 'defaults', 'defaults', 'Defaults', 'DefaultsPanel'],
  [locationPanel, 'location', 'location', 'Location', 'LocationPanel'],
];

for (const [panel, name, needs, slot, view] of each) {
  test(`should open the ${name} panel in its sheet, when the device has ${needs}, its view on the device`, async () => {
    assert.equal(panel.name, name);
    assert.equal(panel.needs, needs);
    assert.equal(panel.slot, slot);
    const calls = [];
    await withWindow({ [view]: viewClass(calls) }, () => {
      const host = {};
      const handle = panel.mount(host, { device: { id: 'D' }, control: control() });
      handle.detach();
      assert.deepEqual(calls.filter((c) => c[0] !== 'refresh'), [['attach', host, 'D'], ['detach']]);
    });
  });
}

test('should refresh what the network, defaults and location panels show each time they open again', async () => {
  for (const [panel, , , , view] of each.filter(([p]) => [networkPanel, defaultsPanel, locationPanel].includes(p))) {
    const calls = [];
    await withWindow({ [view]: viewClass(calls) }, () => {
      panel.mount({}, { device: { id: 'D' }, control: control() }).reopened();
      assert.deepEqual(calls.at(-1), ['refresh']);
    });
  }
});

test('should mark the camera control while the camera streams', async () => {
  let view;
  await withWindow({ CameraPanel: class { attach() { view = this; } } }, () => {
    const marked = control();
    cameraPanel.mount({}, { device: { id: 'D' }, control: marked });
    view.onPhaseChange('streaming');
    assert.ok(marked.classes.has('streaming'));
    view.onPhaseChange('idle');
    assert.ok(!marked.classes.has('streaming'));
  });
});

test('should mark the network control armed, in words too, when a throttle is on', async () => {
  let view;
  await withWindow({ NetworkPanel: class { attach() { view = this; } } }, () => {
    const marked = control();
    networkPanel.mount({}, { device: { id: 'D' }, control: marked });
    view.onArmedChange({ isConditioning: true, describe: () => '3G' });
    assert.ok(marked.classes.has('conditioning'));
    assert.equal(marked.attributes['aria-label'], 'Network conditioning on — 3G');
    view.onArmedChange({ isConditioning: false, describe: () => '' });
    assert.equal(marked.attributes.title, 'Network conditioning off');
  });
});

test('should watch the device for a throttle armed elsewhere, before the network panel ever opens', async () => {
  await withWindow({ setInterval: () => 1 }, async () => {
    globalThis.fetch = async (url) => ({ ok: url === '/devices/D/network', json: async () => ({ active: true, summary: 'Edge' }) });
    const marked = control();
    networkPanel.watch({ device: { id: 'D' }, control: marked });
    await new Promise((r) => setTimeout(r, 0));
    assert.ok(marked.classes.has('conditioning'));
    assert.equal(marked.attributes.title, 'Network conditioning on — Edge');
  });
});

test('should place each panel\'s control in the toolbar cluster it belongs to, under its own label', async () => {
  const { logsPanel } = await import('../../../Sources/Baguette/Resources/Web/panels/logs/logs-panel.js');
  const placed = [statusBarPanel, locationPanel, notifyPanel, cameraPanel, networkPanel, logsPanel, defaultsPanel]
    .map((panel) => [panel.cluster, panel.label]);
  assert.deepEqual(placed, [
    ['simulate', 'Status bar'], ['simulate', 'Location'], ['simulate', 'Notification'], ['simulate', 'Camera'],
    ['simulate', 'Network'], ['inspect', 'Logs'], ['inspect', 'Defaults'],
  ]);
});
