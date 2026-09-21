'use strict';

// BookPose — how the flat view draws a foldable at a hinge angle.

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

test('closing past the open pose, the left half folds over onto the right', () => {
  const BookPose = load();
  assert.deepEqual(BookPose.leaves(0), { left: 180, right: 0 });
  assert.deepEqual(BookPose.leaves(65), { left: 86.25, right: -28.75 });
  for (const a of [0, 30, 65, 100, 130, 160, 180]) {
    const { left, right } = BookPose.leaves(a);
    assert.ok(Math.abs(left - right - (180 - a)) < 0.02, `angle ${a}`);
  }
});

test('the crease is faint when flat and darkens with the fold', () => {
  const BookPose = load();
  assert.equal(BookPose.creaseOpacity(180), 0.05);
  assert.equal(BookPose.creaseOpacity(0), 0.25);
  assert.ok(BookPose.creaseOpacity(130) > 0.05 && BookPose.creaseOpacity(130) < 0.12);
  assert.equal(BookPose.creaseOpacity(200), 0.05);
});

// Sizes are the device's own, unrotated.
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

test('the cover on the book overhangs its half by the shapes the two differ by', () => {
  const BookPose = load();
  assert.equal(BookPose.coverOverhang(462, 660, 514 / 706), (660 * 514 / 706 - 462) / 2);
  assert.ok(BookPose.coverOverhang(500, 660, 514 / 706) < 0);
});

// Perspective makes a bent half's outer edge look taller than the flat device.
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

test('the book is shifted to stay centred as it folds', () => {
  const BookPose = load();
  assert.equal(BookPose.shift(180, 200), 0);
  assert.equal(BookPose.shift(130, 200), 0);
  assert.equal(BookPose.shift(0, 200), -100);
  assert.ok(Math.abs(BookPose.shift(65, 100) - -40.57) < 0.05);
});
