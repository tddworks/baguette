'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const { AXInspector } = loadBrowserModule(path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web', 'sim-ax-inspector.js'
));

function hover(tree, x, y) {
  const inspector = Object.assign(Object.create(AXInspector.prototype), {
    tree, hover: null,
    screenArea: { getBoundingClientRect: () => ({ left: 10, top: 20, width: 200, height: 400 }) },
    getDeviceSize: () => ({ w: 400, h: 800 }),
    _draw() {},
  });
  inspector._handleMove({ clientX: 10 + x / 2, clientY: 20 + y / 2 });
  return inspector.hover;
}

function node(frame, children = [], hidden = false) {
  return { frame, children, hidden };
}

for (const extent of [0, 10]) {
  test(`hover reaches a button outside its ${extent} × ${extent} AX container`, () => {
    const button = node({ x: 100, y: 150, width: 80, height: 40 });
    const root = node({ x: 0, y: 0, width: extent, height: extent }, [button]);
    assert.equal(hover(root, 140, 170), button);
  });
}

test('hidden containers hide their descendants without blocking visible siblings', () => {
  const frame = { x: 100, y: 150, width: 80, height: 40 };
  const visible = node(frame);
  const hidden = node(frame, [node(frame)], true);
  const root = node({ x: 0, y: 0, width: 400, height: 800 }, [visible, hidden]);
  assert.equal(hover(root, 140, 170), visible);
});

test('hover preserves last-sibling priority and falls back to the parent outside child bounds', () => {
  const frame = { x: 100, y: 150, width: 80, height: 40 };
  const topmost = node(frame);
  const root = node({ x: 0, y: 0, width: 400, height: 800 }, [node(frame), topmost]);
  assert.equal(hover(root, 140, 170), topmost);
  assert.equal(hover(root, 180, 170), root);
  assert.equal(hover(root, 400, 800), null);
});

function inspectorWith(tree) {
  const statuses = [];
  const inspector = Object.assign(Object.create(AXInspector.prototype), {
    tree, hover: null, _draw() {}, _setStatus(s) { statuses.push(s); },
  });
  return { inspector, statuses };
}

test('a failed refresh keeps the tree already drawn, and says why', () => {
  const tree = node({ x: 0, y: 0, width: 400, height: 800 });
  const { inspector, statuses } = inspectorWith(tree);

  inspector.handleEnvelope({ type: 'describe_ui_result', ok: false, error: 'the phone closed the connection' });

  assert.equal(inspector.tree, tree);
  assert.equal(statuses.at(-1), 'the phone closed the connection');
});

test('a fresh tree replaces the one drawn', () => {
  const fresh = node({ x: 0, y: 0, width: 400, height: 800 });
  const { inspector } = inspectorWith(node({ x: 0, y: 0, width: 1, height: 1 }));

  inspector.handleEnvelope({ type: 'describe_ui_result', ok: true, tree: fresh });

  assert.equal(inspector.tree, fresh);
});
