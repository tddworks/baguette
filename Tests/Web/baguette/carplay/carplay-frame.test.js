import test from 'node:test';
import assert from 'node:assert/strict';
import { CarPlayFrame } from '../../../../Sources/Baguette/Resources/Web/baguette/carplay/carplay-frame.js';
import { CarPlayFrameDefinition } from '../../../../Sources/Baguette/Resources/Web/baguette/carplay/frame-definition.js';

const CUPRA = {
  schemaVersion: 1,
  id: 'cupra',
  displayName: 'Cupra',
  viewport: { width: 1920, height: 842 },
  screen: { x: 0, y: 0, width: 1920, height: 752, clipRadius: 0 },
  layers: [{
    id: 'climate',
    image: 'climate-bar.png',
    rect: { x: 0, y: 752, width: 1920, height: 90 },
    z: 'above',
  }],
  stream: { defaultSize: { width: 800, height: 450 }, fit: 'contain' },
};

/** Minimal DOM stubs for mount. */
function fakeContainer() {
  const children = [];
  const classList = new Set();
  const el = {
    children,
    style: {},
    classList: {
      add(name) { classList.add(name); },
      remove(name) { classList.delete(name); },
      contains(name) { return classList.has(name); },
    },
    get innerHTML() {
      return children.length ? 'x' : '';
    },
    set innerHTML(v) {
      if (v === '') children.length = 0;
    },
    appendChild(child) {
      children.push(child);
      child.parentNode = el;
      return child;
    },
    removeChild(child) {
      const i = children.indexOf(child);
      if (i >= 0) children.splice(i, 1);
      child.parentNode = null;
      return child;
    },
  };
  return el;
}

function fakeDocument() {
  return {
    createElement(tag) {
      const style = {};
      const attrs = {};
      const kids = [];
      const node = {
        tagName: tag.toUpperCase(),
        style,
        children: kids,
        parentNode: null,
        setAttribute(k, v) { attrs[k] = String(v); },
        getAttribute(k) { return attrs[k]; },
        appendChild(child) {
          kids.push(child);
          child.parentNode = node;
          return child;
        },
      };
      if (tag === 'canvas') {
        node.width = 0;
        node.height = 0;
      }
      if (tag === 'img') {
        node.draggable = false;
        Object.defineProperty(node, 'src', {
          get() { return attrs.src || ''; },
          set(v) { attrs.src = v; },
        });
      }
      return node;
    },
  };
}

test('should mount the screen cutout and climate layer and hand back the canvas', () => {
  const def = CarPlayFrameDefinition.parse(CUPRA);
  const frame = new CarPlayFrame(def, {
    assetBaseUrl: '/carplay-frames/cupra/',
  });
  const container = fakeContainer();
  container.ownerDocument = fakeDocument();
  const ports = frame.mount(container);

  assert.ok(ports.screenArea);
  assert.ok(ports.canvas);
  assert.equal(ports.canvas.id, 'nativeCarPlayCanvas');
  assert.equal(ports.canvas.width, 800);
  assert.equal(ports.canvas.height, 450);
  assert.ok(container.classList.contains('carplay-frame--mounted'));

  const wrapper = container.children[0];
  assert.ok(wrapper);
  // screen + climate layer (above)
  assert.equal(wrapper.children.length, 2);
  const climate = wrapper.children[1];
  assert.equal(climate.tagName, 'IMG');
  assert.equal(climate.getAttribute('data-layer'), 'climate');
  assert.match(climate.style.cssText, /pointer-events:\s*none/);
  assert.ok(climate.src.includes('climate-bar.png'));

  const screenPct = def.screenRectPct();
  assert.equal(ports.screenArea.style.left, screenPct.left + '%');
  assert.equal(ports.screenArea.style.height, screenPct.height + '%');
});

test('should clear the mount and its mounted class when detached', () => {
  const def = CarPlayFrameDefinition.parse(CUPRA);
  const frame = new CarPlayFrame(def, {
    assetBaseUrl: '/carplay-frames/cupra/',
  });
  const container = fakeContainer();
  container.ownerDocument = fakeDocument();
  frame.mount(container);
  frame.detach();
  assert.equal(container.children.length, 0);
  assert.equal(container.classList.contains('carplay-frame--mounted'), false);
});
