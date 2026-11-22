import test from 'node:test';
import assert from 'node:assert/strict';
import { ScreenQuad } from '../../../../Sources/Baguette/Resources/Web/baguette/gestures/screen-quad.js';

// Forward bilinear interpolation — the inverse of what `locate` solves.
// Used only to derive known-good (u,v)->(x,y) fixtures for round-trip tests.
function forwardBilinear(quad, u, v) {
  const { topLeft: a, topRight: b, bottomRight: c, bottomLeft: d } = quad;
  return {
    x: (1 - u) * (1 - v) * a.u + u * (1 - v) * b.u + u * v * c.u + (1 - u) * v * d.u,
    y: (1 - u) * (1 - v) * a.v + u * (1 - v) * b.v + u * v * c.v + (1 - u) * v * d.v,
  };
}

test('should build a quad from the server\'s four corners', () => {
  const SQ = ScreenQuad;
  const quad = SQ.fromCorners([[0.1, 0.2], [0.9, 0.2], [0.9, 0.8], [0.1, 0.8]]);
  assert.deepEqual(quad.topLeft, { u: 0.1, v: 0.2 });
  assert.deepEqual(quad.topRight, { u: 0.9, v: 0.2 });
  assert.deepEqual(quad.bottomRight, { u: 0.9, v: 0.8 });
  assert.deepEqual(quad.bottomLeft, { u: 0.1, v: 0.8 });
});

test('should build no quad from malformed corners', () => {
  const SQ = ScreenQuad;
  assert.equal(SQ.fromCorners(null), null);
  assert.equal(SQ.fromCorners([]), null);
  assert.equal(SQ.fromCorners([[0, 0], [1, 0], [1, 1]]), null);
});

test('should locate every corner and the centre of a rectangular quad', () => {
  const SQ = ScreenQuad;
  const quad = SQ.fromCorners([[0.3, 0.2], [0.7, 0.2], [0.7, 0.8], [0.3, 0.8]]);

  for (const [u, v] of [[0, 0], [1, 0], [1, 1], [0, 1], [0.5, 0.5], [0.25, 0.75]]) {
    const { x, y } = forwardBilinear(quad, u, v);
    const located = quad.locate(x, y);
    assert.ok(Math.abs(located.u - u) < 1e-6, `u: ${located.u} vs ${u}`);
    assert.ok(Math.abs(located.v - v) < 1e-6, `v: ${located.v} vs ${v}`);
    assert.equal(located.inside, true);
  }
});

test('should locate points on a skewed trapezoid too', () => {
  const SQ = ScreenQuad;
  const quad = SQ.fromCorners([[0.35, 0.15], [0.55, 0.25], [0.6, 0.85], [0.3, 0.75]]);

  for (const [u, v] of [[0, 0], [1, 0], [1, 1], [0.5, 0.5], [0.2, 0.9]]) {
    const { x, y } = forwardBilinear(quad, u, v);
    const located = quad.locate(x, y);
    assert.ok(Math.abs(located.u - u) < 1e-6, `u: ${located.u} vs ${u}`);
    assert.ok(Math.abs(located.v - v) < 1e-6, `v: ${located.v} vs ${v}`);
  }
});

test('should place a point well outside the quad outside', () => {
  const SQ = ScreenQuad;
  const quad = SQ.fromCorners([[0.3, 0.2], [0.7, 0.2], [0.7, 0.8], [0.3, 0.8]]);
  const located = quad.locate(0.0, 0.0);
  assert.equal(located.inside, false);
});

test('should place a point right on the quad\'s edge inside despite rounding', () => {
  const SQ = ScreenQuad;
  const quad = SQ.fromCorners([[0.3, 0.2], [0.7, 0.2], [0.7, 0.8], [0.3, 0.8]]);
  const located = quad.locate(0.3, 0.8); // exact bottomLeft corner
  assert.equal(located.inside, true);
});

test('should fill the whole box when the aspect ratios match', () => {
  const SQ = ScreenQuad;
  const canvas = {
    width: 320, height: 240,
    getBoundingClientRect: () => ({ left: 10, top: 20, width: 640, height: 480 }),
  };
  const rect = SQ.contentRect(canvas);
  assert.deepEqual(rect, { left: 10, top: 20, width: 640, height: 480 });
});

test('should letterbox top and bottom when the box is wider than the content', () => {
  const SQ = ScreenQuad;
  // content is 1:1 (square), box is 2:1 (wide) -> pillarboxed sides, full height used
  const canvas = {
    width: 100, height: 100,
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 200, height: 100 }),
  };
  const rect = SQ.contentRect(canvas);
  assert.equal(rect.height, 100);
  assert.equal(rect.width, 100);
  assert.equal(rect.left, 50);
  assert.equal(rect.top, 0);
});

test('should map a click past pillarbox gutters onto the content', () => {
  const SQ = ScreenQuad;
  const canvas = {
    width: 800, height: 480,
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 255.3, height: 100 }),
  };
  const size = { width: 800, height: 480 };
  const content = SQ.contentRect(canvas);
  const clientX = content.left + (160 / 800) * content.width;
  const clientY = content.top + (140 / 480) * content.height;
  const point = SQ.mapClientPointFromContain(canvas, clientX, clientY, size);
  assert.ok(Math.abs(point.x - 160) < 0.5, `x: ${point.x} vs 160`);
  assert.ok(Math.abs(point.y - 140) < 0.5, `y: ${point.y} vs 140`);
  assert.equal(point.inside, true);
});

test('should map a click like the full box when the aspects match', () => {
  const SQ = ScreenQuad;
  const canvas = {
    width: 800, height: 480,
    getBoundingClientRect: () => ({ left: 10, top: 20, width: 800, height: 480 }),
  };
  const size = { width: 800, height: 480 };
  const point = SQ.mapClientPointFromContain(canvas, 410, 260, size);
  assert.ok(Math.abs(point.x - 400) < 0.5, `x: ${point.x} vs 400`);
  assert.ok(Math.abs(point.y - 240) < 0.5, `y: ${point.y} vs 240`);
  assert.equal(point.inside, true);
});

test('should place a click in a gutter outside', () => {
  const SQ = ScreenQuad;
  const canvas = {
    width: 800, height: 480,
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 255.3, height: 100 }),
  };
  const size = { width: 800, height: 480 };
  const content = SQ.contentRect(canvas);
  const point = SQ.mapClientPointFromContain(canvas, content.left - 1, content.top + 50, size);
  assert.equal(point.inside, false);
});
