// WebCodecs' VideoDecoder as the browser behaves: once it reports an error
// it is closed for good — it decodes and configures nothing more.

import test from 'node:test';
import assert from 'node:assert/strict';
import { FrameDecoder } from '../../../Sources/Baguette/Resources/Web/stream/frame-decoder.js';

class FakeVideoDecoder {
  constructor({ output, error }) {
    this.output = output;
    this.error = error;
    this.state = 'unconfigured';
    this.configs = [];
    this.chunks = [];
    FakeVideoDecoder.made.push(this);
  }
  configure(config) {
    if (this.state === 'closed') throw new Error('InvalidStateError: closed');
    this.configs.push(config);
    this.state = 'configured';
  }
  decode(chunk) {
    if (this.state !== 'configured') throw new Error('InvalidStateError: ' + this.state);
    this.chunks.push(chunk);
  }
  close() { this.state = 'closed'; }
  /** What the browser does on a bad chunk or a lost GPU decoder. */
  fail(message) {
    this.state = 'closed';
    this.error(new Error(message));
  }
}

function withWebCodecs(run) {
  FakeVideoDecoder.made = [];
  const saved = { VideoDecoder: globalThis.VideoDecoder, EncodedVideoChunk: globalThis.EncodedVideoChunk };
  globalThis.VideoDecoder = FakeVideoDecoder;
  globalThis.EncodedVideoChunk = class { constructor(init) { Object.assign(this, init); } };
  try { return run(); } finally { Object.assign(globalThis, saved); }
}

function avccDecoder() {
  const logs = [];
  const decoder = FrameDecoder.create('avcc', {
    onFrame: () => {},
    onLog: (message, isError) => logs.push({ message, isError }),
  });
  return { decoder, logs };
}

// One WebSocket message: [tag][payload]. The description's bytes 1–3 name
// the profile, as an avcC record's do.
const message = (tag, ...payload) => ({ data: new Uint8Array([tag, ...payload]).buffer });
const description = message(0x01, 0x01, 0x64, 0x00, 0x33, 0xff);
const keyframe = message(0x02, 0xaa);
const delta = message(0x03, 0xbb);

test('should keep decoding from the next keyframe after the browser decoder fails', () => {
  withWebCodecs(() => {
    const { decoder } = avccDecoder();
    decoder.feed(description);
    decoder.feed(keyframe);
    FakeVideoDecoder.made[0].fail('Decoding error.');

    decoder.feed(keyframe);
    decoder.feed(delta);

    const replacement = FakeVideoDecoder.made.at(-1);
    assert.notEqual(replacement, FakeVideoDecoder.made[0]);
    assert.equal(replacement.configs.length, 1);
    assert.equal(replacement.configs[0].codec, 'avc1.640033');
    assert.deepEqual(replacement.chunks.map((c) => c.type), ['key', 'delta']);
  });
});

test('should skip deltas after the browser decoder fails until a keyframe arrives', () => {
  withWebCodecs(() => {
    const { decoder } = avccDecoder();
    decoder.feed(description);
    decoder.feed(keyframe);
    FakeVideoDecoder.made[0].fail('Decoding error.');

    decoder.feed(delta);
    decoder.feed(delta);

    const decodedSince = FakeVideoDecoder.made.slice(1).flatMap((d) => d.chunks);
    assert.deepEqual(decodedSince, []);
  });
});

test('should say why the browser decoder failed', () => {
  withWebCodecs(() => {
    const { decoder, logs } = avccDecoder();
    decoder.feed(description);
    FakeVideoDecoder.made[0].fail('Decoding error.');

    assert.ok(logs.some((l) => l.isError && l.message.includes('Decoding error.')));
  });
});

// ── which codec a description record is ─────────────────────────────

test('should name an H.264 stream from its avcC record', () => {
  assert.equal(FrameDecoder.codecOf(new Uint8Array([0x01, 0x64, 0x00, 0x33, 0xff])), 'avc1.640033');
});

test('should name an HEVC stream from its hvcC record', () => {
  // Main profile, compatible with Main and Main 10, constraints 0x90, level 93 (3.1).
  const hvcC = new Uint8Array([0x01, 0x01, 0x60, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 93, 0xf0]);
  assert.equal(FrameDecoder.codecOf(hvcC), 'hvc1.1.6.L93.90');
});

test('should name a high-tier HEVC stream with its tier', () => {
  const hvcC = new Uint8Array([0x01, 0x21, 0x60, 0x00, 0x00, 0x00, 0xb0, 0x00, 0x00, 0x00, 0x00, 0x00, 153, 0xf0]);
  assert.equal(FrameDecoder.codecOf(hvcC), 'hvc1.1.6.H153.B0');
});

test('should configure the browser decoder for HEVC when the stream sends an hvcC record', () => {
  withWebCodecs(() => {
    const arrived = [];
    const decoder = FrameDecoder.create('avcc', { onFrame: () => {}, onCodec: (type) => arrived.push(type) });
    decoder.feed(message(0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 93, 0xf0));
    assert.equal(FakeVideoDecoder.made[0].configs[0].codec, 'hvc1.1.6.L93.90');
    assert.deepEqual(arrived, ['video/H265']);
  });
});

test('should tell the page an H.264 stream arrived in H.264', () => {
  withWebCodecs(() => {
    const arrived = [];
    const decoder = FrameDecoder.create('avcc', { onFrame: () => {}, onCodec: (type) => arrived.push(type) });
    decoder.feed(description);
    assert.deepEqual(arrived, ['video/H264']);
  });
});
