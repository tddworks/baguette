// A share's page following its viewer: the display is this screen's shape, so
// when the device turns it is made again in the new shape and the page
// reloads onto it; leaving the page ends the share, and the display goes. The
// shape is the server's. `browser` is everything this touches of the page:
//
//   { width, height, devicePixelRatio, userAgent, location, fetch,
//     on(event, fn), setTimeout, clearTimeout }

/** A turn resizes several times before it settles. */
const SETTLE_MS = 700;

export function followShare(share, macShare, browser) {
  const id = encodeURIComponent(share.id);
  const size = () => ({ width: browser.width, height: browser.height });
  let shown = size();
  let reshaping = false;
  let settle = null;

  /** Ask for the display in `screen`'s shape; whether the Mac made it. */
  const remake = async (screen) => {
    const body = macShare.request({
      viewport: screen, pixelRatio: browser.devicePixelRatio, userAgent: browser.userAgent,
      room: share.room || undefined,
    });
    try {
      return (await browser.fetch('/mac/shares/' + id, { method: 'PUT', body: JSON.stringify(body) })).ok;
    } catch { return false; }
  };

  const reshape = async () => {
    if (reshaping) return;
    reshaping = true;
    try {
      let target = size();
      while (macShare.turned(shown, target)) {
        // Refused: the display keeps its shape, and so does `shown` — the next turn asks again.
        if (!(await remake(target))) return;
        shown = target;
        const now = size();
        // Turned again while it was remade: remake it once more before showing it.
        if (!macShare.turned(shown, now)) { macShare.reloadKeepingShare(browser.location); return; }
        target = now;
      }
    } finally {
      reshaping = false;
    }
  };

  browser.on('resize', () => {
    browser.clearTimeout(settle);
    settle = browser.setTimeout(reshape, SETTLE_MS);
  });
  browser.on('pagehide', () => {
    if (reshaping || !macShare.leaving()) return;
    try { browser.fetch('/mac/shares/' + id, { method: 'DELETE', keepalive: true }); } catch { /* the server ends nothing */ }
  });
}
