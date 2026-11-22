import test from 'node:test';
import assert from 'node:assert/strict';
import { StreamCodec } from '../../../Sources/Baguette/Resources/Web/stream/stream-codec.js';

test('should pick HEVC when nothing was chosen', () => {
  assert.equal(StreamCodec.pick(null, null).id, 'hevc');
});

test('should pick the codec this browser stored', () => {
  assert.equal(StreamCodec.pick(null, 'h264').id, 'h264');
  assert.equal(StreamCodec.pick(null, 'hevc').id, 'hevc');
});

test('should let the page address override the stored codec', () => {
  assert.equal(StreamCodec.pick('h264', 'hevc').id, 'h264');
  assert.equal(StreamCodec.pick('h265', 'h264').id, 'hevc');
  assert.equal(StreamCodec.pick('auto', 'h264').id, 'hevc');
});

test('should pick HEVC when the stored codec is one it does not know', () => {
  assert.equal(StreamCodec.pick(null, 'vp9').id, 'hevc');
  assert.equal(StreamCodec.pick('vp9', null).id, 'hevc');
});

test('should ask the server for HEVC with H.264 to fall back on when HEVC is chosen', () => {
  assert.equal(StreamCodec.named('hevc').asked, 'auto');
});

test('should ask the server for H.264 only when H.264 is chosen', () => {
  assert.equal(StreamCodec.named('h264').asked, 'h264');
});

test('should name the codec a stream arrived in from its media type', () => {
  assert.equal(StreamCodec.arrived('video/H265').id, 'hevc');
  assert.equal(StreamCodec.arrived('video/H264').id, 'h264');
  assert.equal(StreamCodec.arrived('video/VP8'), null);
  assert.equal(StreamCodec.arrived(undefined), null);
});

test('should say HEVC fell back to H.264 when the stream arrived in H.264', () => {
  assert.match(StreamCodec.named('hevc').note(StreamCodec.named('h264')), /H\.264/);
  assert.equal(StreamCodec.named('hevc').note(StreamCodec.named('hevc')), null);
  assert.equal(StreamCodec.named('h264').note(StreamCodec.named('h264')), null);
  assert.equal(StreamCodec.named('hevc').note(null), null);
});

test('should ask a WebSocket stream for HEVC when HEVC is chosen and this browser decodes it', () => {
  assert.equal(StreamCodec.named('hevc').forSocket({ decodesHEVC: true }), 'auto');
});

test('should ask a WebSocket stream for H.264 when this browser cannot decode HEVC', () => {
  assert.equal(StreamCodec.named('hevc').forSocket({ decodesHEVC: false }), 'h264');
});

test('should ask a WebSocket stream for H.264 when H.264 is chosen', () => {
  assert.equal(StreamCodec.named('h264').forSocket({ decodesHEVC: true }), 'h264');
});
