import test from 'node:test';
import assert from 'node:assert/strict';
import { AXInspector } from '../../../Sources/Baguette/Resources/Web/page/internal/accessibility-inspector.js';

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
  test(`should reach a button on hover when it lies outside its ${extent} × ${extent} AX container`, () => {
    const button = node({ x: 100, y: 150, width: 80, height: 40 });
    const root = node({ x: 0, y: 0, width: extent, height: extent }, [button]);
    assert.equal(hover(root, 140, 170), button);
  });
}

test('should hide a hidden container\'s descendants without blocking its visible siblings', () => {
  const frame = { x: 100, y: 150, width: 80, height: 40 };
  const visible = node(frame);
  const hidden = node(frame, [node(frame)], true);
  const root = node({ x: 0, y: 0, width: 400, height: 800 }, [visible, hidden]);
  assert.equal(hover(root, 140, 170), visible);
});

test('should prefer the last sibling on hover, and fall back to the parent outside its children', () => {
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

test('should keep the tree already drawn, and say why, when a refresh fails', () => {
  const tree = node({ x: 0, y: 0, width: 400, height: 800 });
  const { inspector, statuses } = inspectorWith(tree);

  inspector.handleEnvelope({ type: 'describe_ui_result', ok: false, error: 'the phone closed the connection' });

  assert.equal(inspector.tree, tree);
  assert.equal(statuses.at(-1), 'the phone closed the connection');
});

test('should replace the tree drawn when a fresh one arrives', () => {
  const fresh = node({ x: 0, y: 0, width: 400, height: 800 });
  const { inspector } = inspectorWith(node({ x: 0, y: 0, width: 1, height: 1 }));

  inspector.handleEnvelope({ type: 'describe_ui_result', ok: true, tree: fresh });

  assert.equal(inspector.tree, fresh);
});
