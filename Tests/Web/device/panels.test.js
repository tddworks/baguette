import test from 'node:test';
import assert from 'node:assert/strict';
import { Panels } from '../../../Sources/Baguette/Resources/Web/device/panels.js';

// A panel opens in its sheet beside the view: the view says it is open, its
// control shows it, its sheet is reachable; mounted the first time only and
// told when it is opened again.

/** An element of the page, as much of one as the sheet rule touches. */
function element() {
  const attributes = {}, classes = new Set();
  return {
    attributes, inert: true, innerHTML: 'placeholder',
    setAttribute: (k, v) => { attributes[k] = String(v); },
    getAttribute: (k) => (k in attributes ? attributes[k] : null),
    removeAttribute: (k) => { delete attributes[k]; },
    classList: { add: (c) => classes.add(c), remove: (c) => classes.delete(c), contains: (c) => classes.has(c) },
  };
}

function page(...ids) {
  const elements = Object.fromEntries(['simNativeView', ...ids].map((id) => [id, element()]));
  return { elements, element: (id) => elements[id] || null };
}

function logsPanel(mounted) {
  return {
    name: 'logs', needs: 'logs', slot: 'Logs', attribute: 'logs',
    mount(host, { device, control }) {
      mounted.push({ host, device, control });
      return { reopened() { mounted.push('reopened'); } };
    },
  };
}

const device = { id: 'D', can: () => true };

test('should open a panel in its sheet, the view and its control saying so', () => {
  const at = page('nativeLogsHost', 'nativeLogsToggle', 'nativeLogsSheet');
  const panels = new Panels(at, [logsPanel([])]);
  panels.toggle('logs', device);
  assert.equal(at.elements.simNativeView.getAttribute('data-logs'), 'open');
  assert.equal(at.elements.nativeLogsToggle.classList.contains('active'), true);
  assert.equal(at.elements.nativeLogsSheet.getAttribute('aria-hidden'), 'false');
  assert.equal(at.elements.nativeLogsSheet.inert, false);
  assert.equal(panels.isOpen('logs'), true);
});

test('should close an open panel, its sheet out of reach again', () => {
  const at = page('nativeLogsHost', 'nativeLogsToggle', 'nativeLogsSheet');
  const panels = new Panels(at, [logsPanel([])]);
  panels.toggle('logs', device);
  panels.toggle('logs', device);
  assert.equal(at.elements.simNativeView.getAttribute('data-logs'), null);
  assert.equal(at.elements.nativeLogsToggle.classList.contains('active'), false);
  assert.equal(at.elements.nativeLogsSheet.getAttribute('aria-hidden'), 'true');
  assert.equal(at.elements.nativeLogsSheet.inert, true);
});

test('should mount a panel the first time it opens, into its emptied host, and tell it when it opens again', () => {
  const at = page('nativeLogsHost', 'nativeLogsToggle');
  const mounted = [];
  const panels = new Panels(at, [logsPanel(mounted)]);
  panels.toggle('logs', device);
  panels.toggle('logs', device);
  panels.toggle('logs', device);
  assert.equal(mounted.length, 2);
  assert.equal(mounted[0].host, at.elements.nativeLogsHost);
  assert.equal(mounted[0].host.innerHTML, '');
  assert.equal(mounted[0].device, device);
  assert.equal(mounted[0].control, at.elements.nativeLogsToggle);
  assert.equal(mounted[1], 'reopened');
});

test('should do nothing for a panel whose place the page doesn\'t have', () => {
  const at = page();
  const mounted = [];
  new Panels(at, [logsPanel(mounted)]).toggle('logs', device);
  assert.equal(mounted.length, 0);
  assert.equal(at.elements.simNativeView.getAttribute('data-logs'), null);
});

test('should say which ability each panel needs, by its control', () => {
  const panels = new Panels(page(), [logsPanel([])]);
  assert.deepEqual(panels.needs(), { nativeLogsToggle: 'logs' });
});

test('should detach every panel it mounted when the page goes', () => {
  const at = page('nativeLogsHost', 'nativeCamHost');
  const detached = [];
  const panel = (name, slot) => ({ name, needs: name, slot, attribute: name, mount: () => ({ detach: () => detached.push(name) }) });
  const panels = new Panels(at, [panel('logs', 'Logs'), panel('cam', 'Cam'), panel('never', 'Never')]);
  panels.toggle('logs', device);
  panels.toggle('cam', device);
  panels.detach();
  assert.deepEqual(detached.sort(), ['cam', 'logs']);
});

test('should start each panel that watches its device, before it has ever opened', () => {
  const at = page('nativeNetToggle');
  const watching = [];
  const network = { name: 'net', needs: 'network', slot: 'Net', attribute: 'net', mount: () => ({}),
    watch: ({ device: d, control }) => watching.push({ d, control }) };
  new Panels(at, [network, logsPanel([])]).watch(device);
  assert.deepEqual(watching, [{ d: device, control: at.elements.nativeNetToggle }]);
});

test('should leave a panel unwatched when its device can\'t do what it needs', () => {
  const watching = [];
  const network = { name: 'net', needs: 'network', slot: 'Net', attribute: 'net', mount: () => ({}), watch: () => watching.push(1) };
  new Panels(page(), [network]).watch({ id: 'D', can: (a) => a !== 'network' });
  assert.equal(watching.length, 0);
});
