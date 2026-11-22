// MacShare — the page's side of sharing this Mac to the device it runs on
// (`serve --share-mac`, /mac/shares): what it asks for, where the shared
// display opens, and when the device has turned enough to remake it. The
// shape itself is the server's (`SharedScreenShape`); this only reports the
// screen. The Mac family's (docs/features/web-page/design.md).

/** How far a side may change, as a browser bar comes and goes, and still be the same screen. */
const WOBBLE = 0.08;

function viewerName(userAgent) {
  const ua = String(userAgent || '');
  if (/iPad/.test(ua)) return 'iPad';
  if (/iPhone/.test(ua)) return 'iPhone';
  if (/Android/.test(ua)) return 'Android';
  if (/Macintosh/.test(ua)) return 'Mac';
  return 'browser';
}

/**
 * A page's share: the requests it makes, and whether it is leaving or only
 * reloading itself — which is that page's own state, so each page makes one.
 */
export function pageShare() {
  /** Set while the page reloads itself, so that reload doesn't end the share. */
  let keeping = false;

  return {
    /** A shared page's format once its WebRTC offer is refused: the socket's
     *  H.264, which `StreamFormat` swaps for MJPEG where it can't decode. */
    afterRefusal: 'avcc',

    /** Reload the shared display's own page (a turn, a frame picked), keeping its share. */
    reloadKeepingShare(location) {
      keeping = true;
      location.reload();
    },

    /** Whether the page is going for good, so its share should end. */
    leaving() {
      return !keeping;
    },

    /**
     * The body of `POST /mac/shares`.
     * @param {{viewport: {width: number, height: number}, pixelRatio: number,
     *          userAgent: string, room?: string, use?: string}} screen
     */
    request({ viewport, pixelRatio, userAgent, room, use }) {
      const body = {
        viewer: viewerName(userAgent),
        width: Math.floor(viewport.width),
        height: Math.floor(viewport.height),
        scale: pixelRatio || 1,
      };
      if (room) body.room = room;
      if (use) body.use = use;
      return body;
    },

    /** The shared display's page: in the hand, knowing its share, the room it
     *  asked for and the codec (`?codec=h265` on the share page) it streams in. */
    pageAddress(id, room, codec) {
      const enc = encodeURIComponent(id);
      return '/devices/' + enc + '?handheld=1&share=' + enc + (room ? '&room=' + encodeURIComponent(room) : '')
        + (codec ? '&codec=' + encodeURIComponent(codec) : '');
    },

    /** The share a page's address names, and its room; null on any other page. */
    fromAddress(search) {
      const query = new URLSearchParams(search || '');
      const id = query.get('share');
      return id ? { id, room: query.get('room') } : null;
    },

    /** A shared Mac streams over WebRTC — paced, hardware-decoded, smooth on a
     *  phone — unless its tab picked another format (`picked`). */
    format(picked) {
      return picked || 'webrtc';
    },

    /** Whether the screen went from `before` to `now` by turning, or by a real resize. */
    turned(before, now) {
      if ((before.width > before.height) !== (now.width > now.height)) return true;
      const change = (a, b) => Math.abs(a - b) / Math.max(1, a);
      return change(before.width, now.width) > WOBBLE || change(before.height, now.height) > WOBBLE;
    },
  };
}

/** This page's share. */
export const MacShare = pageShare();

// The old scripts reach it here until they're modules too (design §6).
