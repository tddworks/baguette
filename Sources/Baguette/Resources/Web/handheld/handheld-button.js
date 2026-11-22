// HandheldButton — where the handheld mode's floating button rests.
//
// In handheld mode nothing but the simulator is on the glass, so the
// way to its controls (Home, App switcher, Rotate, Leave) is one small
// floating button — the AssistiveTouch idiom an iPhone user already
// knows. Drag it anywhere; let go and it settles against the nearer
// side edge, at the height it was dropped, and stays there next time.
//
// A spot is remembered as `{side, yNorm}` — which edge, and how far
// down the edge's travel — not as pixels, so it comes back to the same
// place after a rotation or a resize. This class owns no DOM: it turns
// a drop point into a spot and a spot into a position; page/device-page.js
// does the dragging and painting.
(function (root) {
  'use strict';

  // Finger travel (CSS px) under which a press is a tap, not a drag —
  // a fingertip wobbles a few pixels on its own.
  const TAP_SLOP = 8;

  const clamp01 = (n) => Math.min(1, Math.max(0, n));

  class HandheldButton {
    /**
     * Where a button dropped with its centre at (`x`, `y`) settles.
     *
     * @param {{x:number, y:number, viewport:{width:number,height:number}, size:number}} drop
     * @returns {{side: 'left'|'right', yNorm: number}}
     */
    static rest({ x, y, viewport, size }) {
      const side = x < viewport.width / 2 ? 'left' : 'right';
      const travel = Math.max(1, viewport.height - size);
      return { side, yNorm: clamp01((y - size / 2) / travel) };
    }

    /**
     * The top-left corner of a button resting at `side` / `yNorm`, kept
     * `margin` in from the edges and clear of the phone's own status
     * bar and home indicator (`insets`, the safe area).
     *
     * @returns {{left: number, top: number}}
     */
    static place({ side, yNorm, viewport, size, margin, insets }) {
      const minTop = insets.top + margin;
      const maxTop = viewport.height - insets.bottom - size - margin;
      const top = minTop + clamp01(yNorm) * Math.max(0, maxTop - minTop);
      const left = side === 'left'
        ? insets.left + margin
        : viewport.width - insets.right - size - margin;
      return { left, top };
    }

    /** A press that lifts close to where it landed is a tap. */
    static isTap({ dx, dy }) {
      return Math.hypot(dx, dy) <= TAP_SLOP;
    }
  }

  root.Baguette = root.Baguette || {};
  root.Baguette._HandheldButton = HandheldButton;
})(window);
