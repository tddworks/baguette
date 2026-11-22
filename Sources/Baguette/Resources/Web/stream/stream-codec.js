// The codec a WebRTC view asks for — HEVC (H.265), falling back to H.264 when
// this browser doesn't offer HEVC, or H.264 only — beside `StreamFormat`,
// which picks the stream itself. The server chooses from what was asked and
// what the browser offered (`?codec=` on /devices/:id/whep, `CodecChoice`).

function codec(id, label, asked, title) {
  return {
    id, label,
    /** What the WHEP route is asked for. */
    asked,
    title,
    /** Why the stream that `arrived` isn't this codec, or null when it is. */
    note(arrived) {
      if (!arrived || arrived.id === this.id) return null;
      return 'Streaming in ' + arrived.label + ': this browser doesn’t offer ' + this.label + '.';
    },
  };
}

const CODECS = [
  codec('hevc', 'HEVC', 'auto', 'HEVC (H.265): sharper for the same bandwidth. Falls back to H.264 when this browser can’t play it.'),
  codec('h264', 'H.264', 'h264', 'H.264 only: plays in every browser.'),
];

/** The page address's spelling (`?codec=`), as the server spells it. */
const SPELLED = { h265: 'hevc', hevc: 'hevc', auto: 'hevc', h264: 'h264' };

export const StreamCodec = {
  ids: CODECS.map((c) => c.id),

  named(id) {
    return CODECS.find((c) => c.id === id) || null;
  },

  /** The codec to ask for: the page address's, else the one stored, else HEVC. */
  pick(addressed, stored) {
    return StreamCodec.named(SPELLED[addressed]) || StreamCodec.named(stored) || CODECS[0];
  },

  /** The codec a stream arrived in, from its media type (`video/H265`), or null. */
  arrived(mimeType) {
    const type = String(mimeType || '').toLowerCase();
    if (type === 'video/h265') return StreamCodec.named('hevc');
    if (type === 'video/h264') return StreamCodec.named('h264');
    return null;
  },
};
