// StreamFormat — which wire format a stream session runs at. Pure.
//
//   StreamFormat.pick(localStorage.getItem('asc.simFormat'),
//                     { hardwareDecoder: FrameDecoder.isHardwareAvailable() })
//
// Capability filters, it doesn't just default: WebCodecs is
// secure-context-only, so a plain-HTTP LAN origin has no `VideoDecoder`
// and must never be handed `avcc`, stored preference or not (issue #71).
(function (root) {
  'use strict';

  // `webrtc` is the phone plane over WHEP (`whep-session.js`); every surface
  // that only has a socket (CarPlay, the watch, the 3D panel) streams its
  // `forSockets` stand-in instead.
  const IDS = ['avcc', 'mjpeg', 'webrtc'];
  const LABELS = { avcc: 'H.264', mjpeg: 'MJPEG', webrtc: 'WebRTC' };

  class StreamFormat {
    /** @param {'avcc'|'mjpeg'|'webrtc'} id the wire spelling, as sent on the URL */
    constructor(id) {
      this.id = id;
    }

    /** Every format this build speaks, best first. */
    static get ids() {
      return IDS.slice();
    }

    /** The named format, or `null` for a spelling this build doesn't speak. */
    static named(id) {
      return IDS.indexOf(id) >= 0 ? new StreamFormat(id) : null;
    }

    static avcc() {
      return new StreamFormat('avcc');
    }

    static mjpeg() {
      return new StreamFormat('mjpeg');
    }

    /** The stored preference, or the best playable format. Absent
     *  `capabilities` reads as no decoder. */
    static pick(stored, capabilities) {
      const wanted = StreamFormat.named(stored);
      if (wanted && wanted.isPlayable(capabilities)) return wanted;
      return StreamFormat.best(capabilities);
    }

    /** The best format the browser can play, ignoring any preference. */
    static best(capabilities) {
      return StreamFormat.avcc().isPlayable(capabilities)
        ? StreamFormat.avcc()
        : StreamFormat.mjpeg();
    }

    /** True when playing this needs WebCodecs rather than an <img> decode. */
    get needsHardwareDecoder() {
      return this.id === 'avcc';
    }

    /** What the format picker calls this one. */
    get label() {
      return LABELS[this.id];
    }

    /** True when a browser with these capabilities could actually play it. */
    isPlayable(capabilities) {
      if (this.id === 'webrtc') return !!(capabilities && capabilities.webrtc);
      if (!this.needsHardwareDecoder) return true;
      return !!(capabilities && capabilities.hardwareDecoder);
    }

    /** What a surface that only has a stream socket plays when this is the
     *  page's format: itself, or for WebRTC the best socket format. */
    forSockets(capabilities) {
      return this.id === 'webrtc' ? StreamFormat.best(capabilities) : this;
    }

    /** The picker's tooltip on a format this browser can't play. */
    get whyUnplayable() {
      if (this.id === 'webrtc') return 'WebRTC is not available in this browser.';
      // Desktop Chrome hides WebCodecs on a plain-http page that isn't
      // localhost; iOS browsers (WebKit) don't, so this is per browser.
      return this.label + ' needs WebCodecs, which this browser only exposes on a '
        + 'secure origin. Open this page over HTTPS or on localhost, or pick WebRTC.';
    }

    /** The wire spelling, so a format drops straight into a URL. */
    toString() {
      return this.id;
    }
  }

  root.StreamFormat = StreamFormat;
})(window);
