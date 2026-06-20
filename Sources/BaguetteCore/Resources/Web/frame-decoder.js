// FrameDecoder — strategy for turning WebSocket frames into paintable
// images, one decoder per format. Pure: no DOM, no WS, no canvas.
//
//   const dec = window.FrameDecoder.create('avcc', {
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
(function () {
  'use strict';

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

  function AvccDecoder({ onFrame, onLog }) {
    let ts = 0;
    const decoder = new VideoDecoder({
      output: (frame) => onFrame(frame),
      error: (err) => onLog && onLog('decoder: ' + err.message, true),
    });
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
          // avcC description — configure the decoder.
          try {
            decoder.configure({
              codec: 'avc1.' + hex2(payload[1]) + hex2(payload[2]) + hex2(payload[3]),
              description: payload.buffer,
              optimizeFor: 'latency',
              hardwareAcceleration: 'prefer-hardware',
            });
          } catch (ex) { onLog && onLog('config: ' + ex.message, true); }
        } else if ((type === 0x02 || type === 0x03) && decoder.state === 'configured') {
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

  window.FrameDecoder = {
    create(format, callbacks) {
      return format === 'avcc'
        ? AvccDecoder(callbacks)
        : MjpegDecoder(callbacks);
    },
    /** True if the browser has WebCodecs `VideoDecoder` for AVCC. */
    isHardwareAvailable() {
      return typeof VideoDecoder !== 'undefined';
    },
  };
})();
