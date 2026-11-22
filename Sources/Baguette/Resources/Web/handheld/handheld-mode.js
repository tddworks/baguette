// HandheldMode — the stream held in the hand, the way a real phone is.
//
// On a desk the page is a workbench: toolbar, rails, the device drawn
// in its bezel. On a phone that same page is a phone inside a phone —
// the live screen ends up under half the glass. Handheld drops all of
// it and gives the simulator's screen the whole view, contain-fit,
// black around it.
//
// This class owns no DOM. It answers the three questions the page has
// to ask — should we be handheld, what address remembers it, how big
// is the screen — and page/device-page.js does the painting. Same split as
// ToolbarFold: the arithmetic is unit-tested, the rendering is
// integration-only.
(function (root) {
  'use strict';

  const PARAM = 'handheld';

  class HandheldMode {
    /**
     * Whether the page should open in the hand.
     *
     * Yes when the address asks (`?handheld`, anything but `0`), and
     * yes when the page was launched from a Home Screen icon — that
     * launch has no browser bars and no workbench to want back.
     *
     * @param {{search: string, standalone: boolean}} where
     */
    static wanted({ search, standalone }) {
      if (standalone) return true;
      const value = new URLSearchParams(search || '').get(PARAM);
      return value !== null && value !== '0';
    }

    /**
     * `href` with handheld remembered (`on`) or forgotten. Living in
     * the address is what lets "Add to Home Screen" save a handheld
     * start page, and a reload come back the way it left.
     *
     * @param {string} href
     * @param {boolean} on
     */
    static href(href, on) {
      const url = new URL(href);
      if (on) url.searchParams.set(PARAM, '1');
      else url.searchParams.delete(PARAM);
      return url.toString();
    }

    /**
     * How this page gets rid of the browser around it.
     *
     *   'standalone'  — launched from a Home Screen icon; there is none.
     *   'browser'     — the browser lets a page go fullscreen (Android,
     *                   desktop); ask it, on the tap that got us here.
     *   'home-screen' — it doesn't. Every iPhone browser is WebKit, and
     *                   WebKit keeps fullscreen for video; the only way
     *                   out of the bars is Add to Home Screen.
     *
     * @param {{standalone: boolean, pageFullscreen: boolean}} where
     */
    static fullscreenRoute({ standalone, pageFullscreen }) {
      if (standalone) return 'standalone';
      return pageFullscreen ? 'browser' : 'home-screen';
    }

    /**
     * The on-page size of the device's portrait screen, contain-fit to
     * the view. In landscape the box is drawn rotated 90°, so it is
     * the rotated footprint — height across, width down — that has to
     * fit.
     *
     * @param {{viewport: {width:number,height:number},
     *          screen:   {width:number,height:number},
     *          orientation: string}} args
     * @returns {{width: number, height: number}}
     */
    static fit({ viewport, screen, orientation }) {
      const sideways = orientation === 'landscape-left' || orientation === 'landscape-right';
      const across = sideways ? screen.height : screen.width;
      const down   = sideways ? screen.width  : screen.height;
      const scale = Math.min(viewport.width / across, viewport.height / down);
      return { width: screen.width * scale, height: screen.height * scale };
    }
  }

  root.Baguette = root.Baguette || {};
  root.Baguette._HandheldMode = HandheldMode;
})(window);
