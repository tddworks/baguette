import test from 'node:test';
import assert from 'node:assert/strict';
import { CaptureSettings } from '../../../Sources/Baguette/Resources/Web/capture/capture-settings.js';

/** localStorage stand-in — a plain map with the same three methods. */
function fakeStorage(seed = {}) {
  const map = new Map(Object.entries(seed));
  return {
    map,
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => map.delete(k),
  };
}

// ── defaults ─────────────────────────────────────────────────

test('should start native, contained, white and framed', () => {
  const s = new (CaptureSettings)();
  assert.equal(s.size.id, 'native');
  assert.equal(s.fit, 'contain');
  assert.equal(s.background, '#ffffff');
  assert.equal(s.withFrame, true);
});

// ── the derived plan ─────────────────────────────────────────

test('should plan a capture through its size', () => {
  const s = new (CaptureSettings)({ size: 'square', fit: 'cover' });
  assert.deepEqual(s.plan(1000, 2000), {
    width: 2000, height: 2000,
    drawX: 0, drawY: -1000, drawW: 2000, drawH: 4000,
    sourceWidth: 1000, sourceHeight: 2000,
  });
});

// Nothing is letterboxed at native size, so a background would only ever
// paint under a fully-opaque image — reporting it as transparent keeps
// PNG captures of a transparent 3D render honest.
test('should report a transparent background at native size', () => {
  const s = new (CaptureSettings)({ size: 'native', background: '#ff0000' });
  assert.equal(s.effectiveBackground, 'transparent');
});

test('should report the chosen background once a size letterboxes', () => {
  const s = new (CaptureSettings)({ size: 'square', background: '#ff0000' });
  assert.equal(s.effectiveBackground, '#ff0000');
});

// ── immutable updates ────────────────────────────────────────

test('should leave the original alone when changed', () => {
  const s = new (CaptureSettings)({ size: 'native' });
  const next = s.with({ size: 'square' });
  assert.equal(s.size.id, 'native');
  assert.equal(next.size.id, 'square');
  assert.equal(next.fit, s.fit);
});

test('should fall back to native when the size is unparseable', () => {
  const s = new (CaptureSettings)({ size: 'not-a-size' });
  assert.equal(s.size.id, 'native');
});

test('should fall back to contain when the fit is unknown', () => {
  assert.equal(new (CaptureSettings)({ fit: 'wat' }).fit, 'contain');
});

// ── the wire / CLI vocabulary ────────────────────────────────

test('should spell the query the Swift routes accept', () => {
  const s = new (CaptureSettings)({
    size: 'appstore-6.9', fit: 'cover', background: '#101010',
  });
  assert.deepEqual(s.toQuery(), {
    size: 'appstore-6.9', fit: 'cover', background: '#101010',
  });
});

test('should leave size and fit out of the query when nothing is resized', () => {
  assert.deepEqual(new (CaptureSettings)().toQuery(), {});
});

test('should name the capture by the size it came out at', () => {
  const s = new (CaptureSettings)({ size: 'appstore-6.9' });
  assert.equal(s.slug(1290, 2796), 'appstore-6.9-1290x2796');
  assert.equal(new (CaptureSettings)().slug(1290, 2796), '1290x2796');
});

// A colon is legal in an HFS+ filename but the Finder renders it as a
// slash, so `16:9-...` shows up as `16/9-...` in the user's Downloads.
// Sanitise here, once, so screenshots and recordings name files the same.
test('should keep a ratio spec filename-safe', () => {
  const s = new (CaptureSettings)({ size: '16:9' });
  assert.equal(s.slug(4971, 2796), '16-9-4971x2796');
});

test('should leave an already-safe spec alone', () => {
  assert.equal(
    new (CaptureSettings)({ size: '1920x1080' }).slug(1920, 1080),
    '1920x1080-1920x1080'
  );
});

// ── persistence ──────────────────────────────────────────────

test('should restore a persisted selection', () => {
  const CS = CaptureSettings;
  const storage = fakeStorage();
  new CS({ size: 'square', fit: 'cover', background: '#222222', withFrame: false })
    .persist(storage, 'asc.capture');

  const restored = CS.restore(storage, 'asc.capture');
  assert.equal(restored.size.id, 'square');
  assert.equal(restored.fit, 'cover');
  assert.equal(restored.background, '#222222');
  assert.equal(restored.withFrame, false);
});

test('should restore defaults when nothing was persisted', () => {
  assert.equal(CaptureSettings.restore(fakeStorage(), 'asc.capture').size.id, 'native');
});

test('should restore defaults when the persisted blob is corrupt', () => {
  const storage = fakeStorage({ 'asc.capture': '{not json' });
  assert.equal(CaptureSettings.restore(storage, 'asc.capture').size.id, 'native');
});

test('should restore defaults when storage throws (Safari private browsing)', () => {
  const CS = CaptureSettings;
  const hostile = {
    getItem() { throw new Error('denied'); },
    setItem() { throw new Error('denied'); },
  };
  assert.equal(CS.restore(hostile, 'asc.capture').size.id, 'native');
  assert.doesNotThrow(() => new CS().persist(hostile, 'asc.capture'));
});
