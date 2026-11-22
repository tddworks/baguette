import test from 'node:test';
import assert from 'node:assert/strict';
import { MacFrameChoices } from '../../../../Sources/Baguette/Resources/Web/families/mac/internal/mac-frame-choices.js';

test('should offer no frame first, then each frame the display fits', () => {
  const choices = MacFrameChoices.of(['iMac 24-inch', 'iMac 27-inch'], null);
  assert.deepEqual(choices.map((c) => c.label), ['No frame', 'iMac 24-inch', 'iMac 27-inch']);
  assert.deepEqual(choices.map((c) => c.pick), [null, 'iMac 24-inch', 'iMac 27-inch']);
});

test('should mark no frame as chosen when nothing is picked', () => {
  const choices = MacFrameChoices.of(['iMac 27-inch'], null);
  assert.deepEqual(choices.map((c) => c.chosen), [true, false]);
});

test('should mark the picked frame as chosen when the display is in one', () => {
  const choices = MacFrameChoices.of(['iMac 24-inch', 'iMac 27-inch'], 'iMac 27-inch');
  assert.deepEqual(choices.map((c) => c.chosen), [false, false, true]);
});

test('should still offer the picked frame when the display no longer fits it', () => {
  const choices = MacFrameChoices.of([], 'iMac 27-inch');
  assert.deepEqual(choices.map((c) => c.label), ['No frame', 'iMac 27-inch']);
  assert.equal(choices[1].chosen, true);
});

test('should offer only no frame when no frame is installed', () => {
  const choices = MacFrameChoices.of(undefined, null);
  assert.deepEqual(choices.map((c) => c.label), ['No frame']);
});
