'use strict';

const test = require('node:test');
const assert = require('node:assert');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const WEB = path.join(__dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web');

function load() {
  return loadBrowserModule(path.join(WEB, 'stream-format.js')).StreamFormat;
}

test('StreamFormat', async (t) => {
  await t.test('should name the three formats the picker offers', () => {
    const StreamFormat = load();
    assert.deepEqual(StreamFormat.ids, ['avcc', 'mjpeg', 'webrtc']);
    assert.equal(StreamFormat.named('webrtc').id, 'webrtc');
    assert.equal(StreamFormat.named('avcc').id, 'avcc');
    assert.equal(StreamFormat.named('mjpeg').id, 'mjpeg');
  });

  await t.test('refuses a spelling it does not speak', () => {
    const StreamFormat = load();
    assert.equal(StreamFormat.named('h265'), null);
    assert.equal(StreamFormat.named(''), null);
    assert.equal(StreamFormat.named(null), null);
    assert.equal(StreamFormat.named(undefined), null);
  });

  await t.test('honours a stored H.264 choice when the browser can decode it', () => {
    const StreamFormat = load();
    assert.equal(StreamFormat.pick('avcc', { hardwareDecoder: true }).id, 'avcc');
  });

  // Issue #71: a stored `avcc` used to short-circuit the probe entirely.
  await t.test('falls back to MJPEG when a stored H.264 choice cannot be decoded', () => {
    const StreamFormat = load();
    assert.equal(StreamFormat.pick('avcc', { hardwareDecoder: false }).id, 'mjpeg');
  });

  await t.test('honours a stored MJPEG choice whatever the browser can decode', () => {
    const StreamFormat = load();
    assert.equal(StreamFormat.pick('mjpeg', { hardwareDecoder: true }).id, 'mjpeg');
    assert.equal(StreamFormat.pick('mjpeg', { hardwareDecoder: false }).id, 'mjpeg');
  });

  await t.test('with nothing stored, takes the best the browser can decode', () => {
    const StreamFormat = load();
    assert.equal(StreamFormat.pick(null, { hardwareDecoder: true }).id, 'avcc');
    assert.equal(StreamFormat.pick(null, { hardwareDecoder: false }).id, 'mjpeg');
  });

  await t.test('treats a format this build no longer speaks as nothing stored', () => {
    const StreamFormat = load();
    assert.equal(StreamFormat.pick('hevc', { hardwareDecoder: true }).id, 'avcc');
    assert.equal(StreamFormat.pick('hevc', { hardwareDecoder: false }).id, 'mjpeg');
  });

  await t.test('reads a missing capabilities argument as no decoder', () => {
    const StreamFormat = load();
    assert.equal(StreamFormat.pick('avcc').id, 'mjpeg');
    assert.equal(StreamFormat.pick(null, {}).id, 'mjpeg');
  });

  await t.test('says which format needs a hardware decoder', () => {
    const StreamFormat = load();
    assert.equal(StreamFormat.named('avcc').needsHardwareDecoder, true);
    assert.equal(StreamFormat.named('mjpeg').needsHardwareDecoder, false);
  });

  await t.test('says whether a browser could play it', () => {
    const StreamFormat = load();
    assert.equal(StreamFormat.named('avcc').isPlayable({ hardwareDecoder: true }), true);
    assert.equal(StreamFormat.named('avcc').isPlayable({ hardwareDecoder: false }), false);
    assert.equal(StreamFormat.named('mjpeg').isPlayable({ hardwareDecoder: false }), true);
  });

  await t.test('carries the label the picker shows', () => {
    const StreamFormat = load();
    assert.equal(StreamFormat.named('avcc').label, 'H.264');
    assert.equal(StreamFormat.named('mjpeg').label, 'MJPEG');
  });

  await t.test('should honour a stored WebRTC choice when the browser has WebRTC', () => {
    const StreamFormat = load();
    assert.equal(StreamFormat.pick('webrtc', { hardwareDecoder: true, webrtc: true }).id, 'webrtc');
    assert.equal(StreamFormat.pick('webrtc', { hardwareDecoder: false, webrtc: true }).id, 'webrtc');
  });

  await t.test('should fall back to the best socket format when the browser has no WebRTC', () => {
    const StreamFormat = load();
    assert.equal(StreamFormat.pick('webrtc', { hardwareDecoder: true, webrtc: false }).id, 'avcc');
    assert.equal(StreamFormat.pick('webrtc', {}).id, 'mjpeg');
  });

  await t.test('should never pick WebRTC when it was not chosen', () => {
    const StreamFormat = load();
    assert.equal(StreamFormat.pick(null, { hardwareDecoder: true, webrtc: true }).id, 'avcc');
    assert.equal(StreamFormat.pick(null, { hardwareDecoder: false, webrtc: true }).id, 'mjpeg');
  });

  await t.test('should give a socket-only surface the best socket format when WebRTC is chosen', () => {
    const StreamFormat = load();
    assert.equal(StreamFormat.named('webrtc').forSockets({ hardwareDecoder: true, webrtc: true }).id, 'avcc');
    assert.equal(StreamFormat.named('webrtc').forSockets({ hardwareDecoder: false, webrtc: true }).id, 'mjpeg');
    assert.equal(StreamFormat.named('mjpeg').forSockets({ hardwareDecoder: true }).id, 'mjpeg');
    assert.equal(StreamFormat.named('avcc').forSockets({ hardwareDecoder: true }).id, 'avcc');
  });

  await t.test('should say why a browser can\'t play it', () => {
    const StreamFormat = load();
    assert.equal(StreamFormat.named('avcc').whyUnplayable,
      'H.264 needs WebCodecs, which this browser only exposes on a secure origin. '
      + 'Open this page over HTTPS or on localhost, or pick WebRTC.');
    assert.equal(StreamFormat.named('webrtc').whyUnplayable, 'WebRTC is not available in this browser.');
    assert.equal(StreamFormat.named('webrtc').label, 'WebRTC');
    assert.equal(StreamFormat.named('webrtc').needsHardwareDecoder, false);
  });

  await t.test('stringifies to the wire spelling', () => {
    const StreamFormat = load();
    assert.equal(String(StreamFormat.named('avcc')), 'avcc');
    assert.equal(`${StreamFormat.named('mjpeg')}`, 'mjpeg');
  });
});
