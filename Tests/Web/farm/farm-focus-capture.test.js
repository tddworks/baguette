// The two pieces of the farm focus pane's capture wiring that are value
// logic rather than DOM: what output size a recording will come out at,
// and what the download gets called. Everything else in farm-focus.js is
// page composition and stays integration-only.

import test from 'node:test';
import assert from 'node:assert/strict';
import { FarmFocus } from '../../../Sources/Baguette/Resources/Web/farm/farm-focus.js';
import { CaptureSettings } from '../../../Sources/Baguette/Resources/Web/capture/capture-settings.js';

function load() {
  return { FarmFocus, CaptureSettings };
}

// A focus pane with no DOM: `show()` is what builds the markup and mounts
// the real picker, and neither is needed to ask what size comes out.
function focusWith({ settings, context }) {
  const { FarmFocus, CaptureSettings } = load();
  const focus = new FarmFocus({ querySelector: () => null });
  focus.captureMenu = { settings: new CaptureSettings(settings) };
  focus._getRecorderContext = () => context;
  return focus;
}

const BEZEL = {
  canvas: { width: 585, height: 1266 },
  frameImg: { naturalWidth: 1290 },
  screen: { viewport: { width: 1290, height: 2796 } },
};

test('should resolve a ratio against the composited bezel, not the scaled canvas', () => {
  const focus = focusWith({ settings: { size: 'square' }, context: BEZEL });
  assert.deepEqual(focus._resolvedOutputSize(), { width: 2796, height: 2796 });
});

test('should resolve against the live canvas when the bezel is left out', () => {
  const focus = focusWith({
    settings: { size: 'square', withFrame: false },
    context: BEZEL,
  });
  assert.deepEqual(focus._resolvedOutputSize(), { width: 1266, height: 1266 });
});

test('should ignore the source entirely for a fixed preset', () => {
  const focus = focusWith({ settings: { size: 'appstore-6.9' }, context: BEZEL });
  assert.deepEqual(focus._resolvedOutputSize(), { width: 1290, height: 2796 });
});

test('should resolve nothing when there is no live canvas to record', () => {
  const focus = focusWith({ settings: { size: 'square' }, context: null });
  assert.equal(focus._resolvedOutputSize(), null);
});

// ── download naming ──────────────────────────────────────────────

function naming(sizeSpec, planned, output) {
  const { CaptureSettings } = load();
  return {
    settings: new CaptureSettings({ size: sizeSpec }),
    plannedSize: planned,
    outputSize: output,
  };
}

function nameOf(sizeSpec, planned, output, filename) {
  const focus = focusWith({ settings: {}, context: null });
  return focus._recordFilename({ filename }, naming(sizeSpec, planned, output));
}

test('should name the download after the size the recording came out at', () => {
  assert.equal(
    nameOf('square', { width: 2796, height: 2796 }, { width: 2796, height: 2796 },
      'simulator-2026.mp4'),
    'simulator-2026-square-2796x2796.mp4'
  );
});

// A recorder that doesn't understand the capture size still produces a
// file — it just isn't the size that was asked for. Naming it after the
// preset anyway would be a lie, so only the real pixels go in.
test('should name plain dimensions, not the preset, when the recorder ignored the size', () => {
  assert.equal(
    nameOf('square', { width: 2796, height: 2796 }, { width: 1290, height: 2796 },
      'simulator-2026.mp4'),
    'simulator-2026-1290x2796.mp4'
  );
});

test('should leave alone a name the recorder already slugged', () => {
  assert.equal(
    nameOf('square', { width: 2796, height: 2796 }, { width: 2796, height: 2796 },
      'simulator-2026-square-2796x2796.mp4'),
    'simulator-2026-square-2796x2796.mp4'
  );
});

test("should keep the recorder's own name for a native recording", () => {
  assert.equal(
    nameOf('native', { width: 1290, height: 2796 }, { width: 1290, height: 2796 },
      'simulator-2026.mp4'),
    'simulator-2026.mp4'
  );
});

test('should never put a colon in the filename for a ratio', () => {
  assert.equal(
    nameOf('16:9', { width: 4971, height: 2796 }, { width: 4971, height: 2796 },
      'simulator-2026.webm'),
    'simulator-2026-16-9-4971x2796.webm'
  );
});
