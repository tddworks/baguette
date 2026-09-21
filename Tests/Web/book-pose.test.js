'use strict';

// BookPose — how the flat view draws a foldable at a hinge angle: the
// cover when shut, the unfolded panel flat when flat, and in between a
// book whose two halves turn about the crease as Device Hub's model does.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'baguette', 'hinge', 'book-pose.js'
);

function load() {
  return loadBrowserModule(MODULE_PATH).Baguette.BookPose;
}

test('shut shows the cover, flat the unfolded panel, anything between the book', () => {
  const BookPose = load();
  assert.equal(BookPose.view(0), 'cover');
  assert.equal(BookPose.view(3.2), 'cover');    // Device Hub's closed pose
  assert.equal(BookPose.view(8), 'book');
  assert.equal(BookPose.view(130), 'book');     // its open pose stays bent
  assert.equal(BookPose.view(177), 'book');
  assert.equal(BookPose.view(179), 'flat');
  assert.equal(BookPose.view(180), 'flat');
});

// The book is the unfolded panel with the cover on its back, so only the
// shut device streams the cover as the view's own panel.
test('the view streams the cover only when shut', () => {
  const BookPose = load();
  assert.equal(BookPose.panel(0), 'primary');
  assert.equal(BookPose.panel(40), 'secondary');
  assert.equal(BookPose.panel(180), 'secondary');
});

test('between open and flat both halves take half the bend, spine centred', () => {
  const BookPose = load();
  assert.deepEqual(BookPose.leaves(180), { left: 0, right: 0 });
  assert.deepEqual(BookPose.leaves(155), { left: 12.5, right: -12.5 });
  assert.deepEqual(BookPose.leaves(130), { left: 25, right: -25 });
});

// The cover is the back of the left half: shutting lays the left half
// onto the right, which settles flat, handing over continuously from
// the open pose down.
test('closing past the open pose, the left half folds over onto the right', () => {
  const BookPose = load();
  assert.deepEqual(BookPose.leaves(0), { left: 180, right: 0 });
  assert.deepEqual(BookPose.leaves(65), { left: 86.25, right: -28.75 });
  for (const a of [0, 30, 65, 100, 130, 160, 180]) {
    const { left, right } = BookPose.leaves(a);
    assert.ok(Math.abs(left - right - (180 - a)) < 0.02, `angle ${a}`);
  }
});

// The crease is a hairline laid flat and deepens as the panel bends.
test('the crease is faint when flat and darkens with the fold', () => {
  const BookPose = load();
  assert.equal(BookPose.creaseOpacity(180), 0.05);
  assert.equal(BookPose.creaseOpacity(0), 0.25);
  assert.ok(BookPose.creaseOpacity(130) > 0.05 && BookPose.creaseOpacity(130) < 0.12);
  assert.equal(BookPose.creaseOpacity(200), 0.05);
});

// One box holds every pose: the unfolded device fills it landscape, the
// cover stands in it as tall as the box, centred — so nothing around it
// moves as the device folds. Sizes are the device's own, unrotated.
test('the unfolded device turned landscape fills the box exactly', () => {
  const BookPose = load();
  const box = { width: 924, height: 660 };
  assert.deepEqual(BookPose.fitDevice(box, 660 / 924, 90), { width: 660, height: 924, left: 132, top: -132 });
});

test('the cover stands as tall as the box, centred', () => {
  const BookPose = load();
  const box = { width: 924, height: 660 };
  const fit = BookPose.fitDevice(box, 514 / 706, 0);
  assert.equal(fit.height, 660);
  assert.equal(Math.round(fit.width), 481);
  assert.equal(Math.round(fit.left), 222);
  assert.equal(fit.top, 0);
});

test('a device wider than the box is held to its width', () => {
  const BookPose = load();
  const fit = BookPose.fitDevice({ width: 400, height: 660 }, 514 / 706, 0);
  assert.equal(fit.width, 400);
  assert.ok(fit.height < 660);
});

// The book's back carries the cover at its own shape, centred on the
// half it lies over when shut — so the shut book is the cover exactly.
test('the cover on the book overhangs its half by the shapes the two differ by', () => {
  const BookPose = load();
  assert.equal(BookPose.coverOverhang(462, 660, 514 / 706), (660 * 514 / 706 - 462) / 2);
  assert.ok(BookPose.coverOverhang(500, 660, 514 / 706) < 0);
});

// Perspective brings a bent half's outer edge toward the viewer, so it
// looks taller than the device laid flat. The box keeps room for Device
// Hub's open pose; any pose that would bulge past it is scaled back in.
test('the box keeps room for the open pose to fill it', () => {
  const BookPose = load();
  assert.ok(BookPose.RESERVE > 1.08 && BookPose.RESERVE < 1.09);
  assert.equal(BookPose.stageScale(180), 1);
  assert.equal(BookPose.stageScale(130), 1);
  assert.equal(BookPose.stageScale(0), 1);
});

test('a half turned toward the viewer is scaled back into the box', () => {
  const BookPose = load();
  const s = BookPose.stageScale(60);   // the left half nearly edge-on
  assert.ok(s < 0.95 && s > 0.85, `scale ${s}`);
  assert.ok(Math.abs(BookPose.magnification(60) * s - BookPose.RESERVE) < 1e-9);
});

// As the book shuts it narrows to its right half; Device Hub keeps the
// device in the middle, so the book slides back by half what it lost.
test('the book is shifted to stay centred as it folds', () => {
  const BookPose = load();
  assert.equal(BookPose.shift(180, 200), 0);
  assert.equal(BookPose.shift(130, 200), 0);
  assert.equal(BookPose.shift(0, 200), -100);
  assert.ok(Math.abs(BookPose.shift(65, 100) - -40.57) < 0.05);
});
