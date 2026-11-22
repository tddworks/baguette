// MacShare — the page's side of sharing this Mac to the device it runs on
// (`serve --share-mac`, /mac/shares): what it asks for, where the shared
// display opens, and when the device has turned enough to remake it. The
// shape itself is the server's (`SharedScreenShape`); this only reports the
// screen.
(function (root) {
  'use strict';

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

  const MacShare = {
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

    /** The shared display's page: in the hand, knowing its share and the room it asked for. */
    pageAddress(id, room) {
      const enc = encodeURIComponent(id);
      return '/devices/' + enc + '?handheld=1&share=' + enc + (room ? '&room=' + encodeURIComponent(room) : '');
    },

    /** The share a page's address names, and its room; null on any other page. */
    fromAddress(search) {
      const query = new URLSearchParams(search || '');
      const id = query.get('share');
      return id ? { id, room: query.get('room') } : null;
    },

    /** Whether the screen went from `before` to `now` by turning, or by a real resize. */
    turned(before, now) {
      if ((before.width > before.height) !== (now.width > now.height)) return true;
      const change = (a, b) => Math.abs(a - b) / Math.max(1, a);
      return change(before.width, now.width) > WOBBLE || change(before.height, now.height) > WOBBLE;
    },
  };

  root.Baguette = root.Baguette || {};
  root.Baguette._MacShare = MacShare;
})(window);
