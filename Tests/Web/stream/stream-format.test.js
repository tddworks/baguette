import test from 'node:test';
import assert from 'node:assert';
import { StreamFormat } from '../../../Sources/Baguette/Resources/Web/stream/stream-format.js';

test('StreamFormat', async (t) => {
  await t.test('should name the three formats the picker offers', () => {
    assert.deepEqual(StreamFormat.ids, ['avcc', 'mjpeg', 'webrtc']);
    assert.equal(StreamFormat.named('webrtc').id, 'webrtc');
    assert.equal(StreamFormat.named('avcc').id, 'avcc');
    assert.equal(StreamFormat.named('mjpeg').id, 'mjpeg');
  });

  await t.test('should refuse a spelling it does not speak', () => {
    assert.equal(StreamFormat.named('h265'), null);
    assert.equal(StreamFormat.named(''), null);
    assert.equal(StreamFormat.named(null), null);
    assert.equal(StreamFormat.named(undefined), null);
  });

  await t.test('should honour a stored H.264 choice when the browser can decode it', () => {
    assert.equal(StreamFormat.pick('avcc', { hardwareDecoder: true }).id, 'avcc');
  });

  // Issue #71: a stored `avcc` used to short-circuit the probe entirely.
  await t.test('should fall back to MJPEG when a stored H.264 choice cannot be decoded', () => {
    assert.equal(StreamFormat.pick('avcc', { hardwareDecoder: false }).id, 'mjpeg');
  });

  await t.test('should honour a stored MJPEG choice whatever the browser can decode', () => {
    assert.equal(StreamFormat.pick('mjpeg', { hardwareDecoder: true }).id, 'mjpeg');
    assert.equal(StreamFormat.pick('mjpeg', { hardwareDecoder: false }).id, 'mjpeg');
  });

  await t.test('should take the best the browser can decode when nothing is stored', () => {
    assert.equal(StreamFormat.pick(null, { hardwareDecoder: true }).id, 'avcc');
    assert.equal(StreamFormat.pick(null, { hardwareDecoder: false }).id, 'mjpeg');
  });

  await t.test('should treat a format this build no longer speaks as nothing stored', () => {
    assert.equal(StreamFormat.pick('hevc', { hardwareDecoder: true }).id, 'avcc');
    assert.equal(StreamFormat.pick('hevc', { hardwareDecoder: false }).id, 'mjpeg');
  });

  await t.test('should read missing capabilities as no decoder', () => {
    assert.equal(StreamFormat.pick('avcc').id, 'mjpeg');
    assert.equal(StreamFormat.pick(null, {}).id, 'mjpeg');
  });

  await t.test('should say which format needs a hardware decoder', () => {
    assert.equal(StreamFormat.named('avcc').needsHardwareDecoder, true);
    assert.equal(StreamFormat.named('mjpeg').needsHardwareDecoder, false);
  });

  await t.test('should say whether a browser could play it', () => {
    assert.equal(StreamFormat.named('avcc').isPlayable({ hardwareDecoder: true }), true);
    assert.equal(StreamFormat.named('avcc').isPlayable({ hardwareDecoder: false }), false);
    assert.equal(StreamFormat.named('mjpeg').isPlayable({ hardwareDecoder: false }), true);
  });

  await t.test('should carry the label the picker shows', () => {
    assert.equal(StreamFormat.named('avcc').label, 'WebSocket');
    assert.equal(StreamFormat.named('mjpeg').label, 'MJPEG');
  });

  await t.test('should honour a stored WebRTC choice when the browser has WebRTC', () => {
    assert.equal(StreamFormat.pick('webrtc', { hardwareDecoder: true, webrtc: true }).id, 'webrtc');
    assert.equal(StreamFormat.pick('webrtc', { hardwareDecoder: false, webrtc: true }).id, 'webrtc');
  });

  await t.test('should fall back to the best socket format when the browser has no WebRTC', () => {
    assert.equal(StreamFormat.pick('webrtc', { hardwareDecoder: true, webrtc: false }).id, 'avcc');
    assert.equal(StreamFormat.pick('webrtc', {}).id, 'mjpeg');
  });

  await t.test('should never pick WebRTC when it was not chosen', () => {
    assert.equal(StreamFormat.pick(null, { hardwareDecoder: true, webrtc: true }).id, 'avcc');
    assert.equal(StreamFormat.pick(null, { hardwareDecoder: false, webrtc: true }).id, 'mjpeg');
  });

  await t.test('should give a socket-only surface the best socket format when WebRTC is chosen', () => {
    assert.equal(StreamFormat.named('webrtc').forSockets({ hardwareDecoder: true, webrtc: true }).id, 'avcc');
    assert.equal(StreamFormat.named('webrtc').forSockets({ hardwareDecoder: false, webrtc: true }).id, 'mjpeg');
    assert.equal(StreamFormat.named('mjpeg').forSockets({ hardwareDecoder: true }).id, 'mjpeg');
    assert.equal(StreamFormat.named('avcc').forSockets({ hardwareDecoder: true }).id, 'avcc');
  });

  await t.test('should say why a browser can\'t play it', () => {
    assert.equal(StreamFormat.named('avcc').whyUnplayable,
      'WebSocket needs WebCodecs, which this browser only exposes on a secure origin. '
      + 'Open this page over HTTPS or on localhost, or pick WebRTC.');
    assert.equal(StreamFormat.named('webrtc').whyUnplayable, 'WebRTC is not available in this browser.');
    assert.equal(StreamFormat.named('webrtc').label, 'WebRTC');
    assert.equal(StreamFormat.named('webrtc').needsHardwareDecoder, false);
  });

  await t.test('should read as the wire spelling when stringified', () => {
    assert.equal(String(StreamFormat.named('avcc')), 'avcc');
    assert.equal(`${StreamFormat.named('mjpeg')}`, 'mjpeg');
  });
});
