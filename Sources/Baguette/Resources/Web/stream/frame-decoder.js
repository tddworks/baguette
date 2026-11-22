// FrameDecoder — strategy for turning WebSocket frames into paintable
// images, one decoder per format. Pure: no DOM, no WS, no canvas.
//
//   const dec = FrameDecoder.create('avcc', {
//     onFrame: (bitmapOrVideoFrame) => …,
//     onLog:   (msg, isErr) => …,
//   });
//   socket.onmessage = (e) => dec.feed(e);
//   // …
//   dec.dispose();
//
// `onFrame` is called with whatever createImageBitmap / VideoDecoder
// emits — both have `displayWidth/Height` (or `width/height`) and
// optional `close()`. Older frames the caller hasn't painted yet
// should be `close()`d before being replaced; the decoder doesn't
// own that responsibility.
function MjpegDecoder({ onFrame, onLog }) {
  return {
    async feed(e) {
      if (e.data instanceof ArrayBuffer) {
        try {
          const bmp = await createImageBitmap(new Blob([e.data], { type: 'image/jpeg' }));
          onFrame(bmp);
        } catch { /* corrupt frame; skip */ }
      } else {
        forwardJSONErrors(e.data, onLog);
      }
    },
    dispose() { /* nothing to release */ },
  };
}

function AvccDecoder({ onFrame, onLog, onCodec }) {
  let ts = 0;
  // A VideoDecoder that reports an error is closed for good: every later
  // chunk would be dropped and the page would sit on its last picture.
  // So the last description is kept, and a closed decoder is replaced
  // at the next keyframe — a delta before it has nothing to refer to.
  let config = null;
  const makeDecoder = () => new VideoDecoder({
    output: (frame) => onFrame(frame),
    error: (err) => onLog && onLog('decoder: ' + err.message + ' — resuming at the next keyframe', true),
  });
  let decoder = makeDecoder();
  return {
    feed(e) {
      if (!(e.data instanceof ArrayBuffer)) {
        forwardJSONErrors(e.data, onLog);
        return;
      }
      if (e.data.byteLength < 2) return;

      const buf = new Uint8Array(e.data);
      const type = buf[0];
      const payload = buf.slice(1);

      if (type === 0x01) {
        // The decoder configuration record (avcC, or hvcC for HEVC) — configure the decoder.
        const codec = codecOf(payload);
        if (onCodec) onCodec(codec.startsWith('hvc1') ? 'video/H265' : 'video/H264');
        config = {
          codec,
          description: payload.buffer,
          optimizeForLatency: true,
          hardwareAcceleration: 'prefer-hardware',
        };
        // Diagnostic only: `prefer-hardware` silently falls back to a
        // software decoder — brutal at full-res 60fps — with no error.
        // `decodingInfo().powerEfficient` flags the hardware path so a
        // fallback shows up in the log instead of as mystery lag.
        const mc = navigator.mediaCapabilities;
        if (mc && typeof mc.decodingInfo === 'function') {
          mc.decodingInfo({
            type: 'file',
            video: {
              contentType: 'video/mp4; codecs="' + config.codec + '"',
              width: 1170, height: 2532, bitrate: 8000000, framerate: 60,
            },
          })
            .then((info) => {
              onLog && onLog(
                'decode: ' + (info.powerEfficient ? 'hardware' : 'SOFTWARE fallback')
                + ' (' + config.codec + ' — supported=' + info.supported
                + ' smooth=' + info.smooth + ' powerEfficient=' + info.powerEfficient + ')'
                + (info.powerEfficient ? '' : ' — H.264 latency will be poor'),
                !info.powerEfficient);
            })
            .catch((err) => {
              onLog && onLog('decode: HW probe failed for ' + config.codec
                + ' — ' + ((err && err.message) || err), true);
            });
        } else {
          onLog && onLog('decode: mediaCapabilities unavailable ('
            + config.codec + ')', true);
        }
        if (decoder.state === 'closed') decoder = makeDecoder();
        try {
          decoder.configure(config);
        } catch (ex) { onLog && onLog('config: ' + ex.message, true); }
      } else if (type === 0x02 || type === 0x03) {
        if (decoder.state === 'closed') {
          if (type !== 0x02 || !config) return;
          decoder = makeDecoder();
          try { decoder.configure(config); } catch (ex) {
            onLog && onLog('config: ' + ex.message, true);
            return;
          }
        }
        if (decoder.state !== 'configured') return;
        // 0x02 = key (IDR), 0x03 = delta.
        try {
          decoder.decode(new EncodedVideoChunk({
            type: type === 0x02 ? 'key' : 'delta',
            timestamp: ts,
            data: payload.buffer,
          }));
          ts += 16667;   // 60 fps tick — value isn't displayed; just monotonic.
        } catch { /* drop frame */ }
      } else if (type === 0x04) {
        // JPEG seed — paints before H.264 IDR lands so the user
        // sees something on connect.
        createImageBitmap(new Blob([payload], { type: 'image/jpeg' }))
          .then(onFrame)
          .catch(() => {});
      }
    },
    dispose() {
      try { decoder.close(); } catch {}
    },
  };
}

function forwardJSONErrors(data, onLog) {
  try {
    const d = JSON.parse(data);
    if ((d.type === 'error' || d.ok === false) && onLog) onLog(d.error || 'error', true);
  } catch { /* not JSON; ignore */ }
}

function hex2(b) { return ('0' + b.toString(16)).slice(-2); }

/** The WebCodecs codec string a decoder configuration record names: `avc1.PPCCLL`
 *  for an avcC record, `hvc1.…` (ISO/IEC 14496-15 Annex E) for an hvcC one. Byte 1
 *  tells them apart: an avcC profile is 66 or more, an hvcC one packs a profile
 *  space, a tier and a profile under 32. */
function codecOf(record) {
  if (record[1] >= 0x40) return 'avc1.' + hex2(record[1]) + hex2(record[2]) + hex2(record[3]);
  const space = record[1] >> 6;
  const tier = (record[1] >> 5) & 1;
  const profile = record[1] & 0x1f;
  let compatible = (record[2] << 24 | record[3] << 16 | record[4] << 8 | record[5]) >>> 0;
  let reversed = 0;
  for (let bit = 0; bit < 32; bit++) { reversed = (reversed << 1 | (compatible & 1)) >>> 0; compatible >>>= 1; }
  const constraints = Array.from(record.slice(6, 12));
  while (constraints.length && constraints[constraints.length - 1] === 0) constraints.pop();
  return ['hvc1', (space ? 'ABC'[space - 1] : '') + profile, reversed.toString(16).toUpperCase(),
    (tier ? 'H' : 'L') + record[12]]
    .concat(constraints.map((b) => b.toString(16).toUpperCase()))
    .join('.');
}

const FrameDecoder = {
  create(format, callbacks) {
    return format === 'avcc'
      ? AvccDecoder(callbacks)
      : MjpegDecoder(callbacks);
  },
  codecOf,
  /** True if the browser has WebCodecs `VideoDecoder` for AVCC. */
  isHardwareAvailable() {
    return typeof VideoDecoder !== 'undefined';
  },
};

export { FrameDecoder };
