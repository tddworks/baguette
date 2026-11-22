// ToolbarFold — what the focus toolbar gives up when the row is too
// narrow, and in what order.
//
// The focus toolbar carries fifteen controls, but only seven ideas:
// Navigate, Stream, View, Control, Simulate, Inspect, Capture. When the
// row will not fit, a WHOLE cluster folds into one menu button — never
// an item, never a partial group. A flat per-control priority queue was
// tried first and tore Shake off Home on a tie-break between equal
// ranks; see docs/mockups/focus-toolbar-overflow.html, which runs both.
//
// This class owns no DOM. The caller hands it a `fits` callback that
// renders a candidate state and reports whether the row fits; it hands
// back the first state that did. That split is the point — the
// arithmetic is unit-tested here and the rendering stays
// integration-only, same bar as page/device-page.js itself.
//
//   const fold = new ToolbarFold(CLUSTERS);
//   const plan = fold.plan((state) => {
//     paint(state);                                   // your DOM
//     return bar.scrollWidth <= bar.clientWidth + 1;  // your measure
//   });
//   plan  // → { folded: ['simulate'], merged: false, tight: false }
//
// Re-measuring after every candidate is deliberate: there is no width
// table to keep in sync with the CSS, and it stays right when a device
// name is long or a webfont lands late.
(function (root) {
  'use strict';

  class ToolbarFold {
    /**
     * @param {Array<{id: string, fold?: number}>} clusters
     *   Array order is where a cluster SITS; `fold` is how hard it
     *   holds on, lowest folding first. A cluster with no `fold` never
     *   folds — Navigate, View and Capture, because Capture is the job.
     */
    constructor(clusters) {
      this.clusters = clusters || [];
    }

    /** The ids that can fold, in the order they will. */
    get order() {
      return this.clusters
        .filter((c) => c.fold)
        .slice()
        .sort((a, b) => a.fold - b.fold)
        .map((c) => c.id);
    }

    /**
     * Offer progressively narrower states to `fits` until one is
     * accepted, and return it.
     *
     * The states, in order:
     *   1. nothing folded
     *   2. …each cluster folded in turn, down the fold order
     *   3. every folded cluster merged into one menu — a LAST RESORT,
     *      not a threshold. Separate cluster buttons keep their
     *      meaning (you can go straight to Simulate), so they survive
     *      until even they will not fit. One folded cluster is already
     *      its own menu, so merging it would swap a named button for
     *      an anonymous one and save nothing.
     *   4. the device name truncates. Everything above either vanishes
     *      into a menu or is pinned; the name is the only control that
     *      can survive at a smaller size, which makes it the cheapest
     *      thing left to give — and the last.
     *
     * The final state is returned whether or not it fit: past step 4
     * there is nothing else to try.
     *
     * @param {(state: {folded: string[], merged: boolean, tight: boolean}) => boolean} fits
     * @returns {{folded: string[], merged: boolean, tight: boolean}}
     */
    plan(fits) {
      const state = { folded: [], merged: false, tight: false };
      if (fits(state)) return state;

      const order = this.order;
      for (let i = 0; i < order.length; i += 1) {
        state.folded.push(order[i]);
        if (fits(state)) return state;
      }

      if (state.folded.length > 1) {
        state.merged = true;
        if (fits(state)) return state;
      }

      state.tight = true;
      fits(state);
      return state;
    }
  }

  root.Baguette = root.Baguette || {};
  root.Baguette._ToolbarFold = ToolbarFold;
})(window);
