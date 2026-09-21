// BookPose — how the flat view draws a foldable at a hinge angle: the
// cover when shut, the unfolded panel when flat, and in between a book —
// the unfolded panel split at the crease, the cover on the back of its
// left half — posed as Device Hub's model is (`FoldPose` on the server):
// above the open pose the bend is centred, below it the left half folds
// over onto the right so the cover ends facing the viewer.
(function (root) {
  'use strict';

  // Device Hub's closed pose reads ≈3°, its open pose 130°.
  const SHUT_DEGREES = 5;
  const FLAT_DEGREES = 178;
  const OPEN_POSE_DEGREES = 130;
  const CREASE_FLAT = 0.05;
  const CREASE_SHUT = 0.25;

  const r2 = (v) => Math.round(v * 100) / 100 || 0;   // no -0

  class BookPose {
    static get OPEN_POSE_DEGREES() { return OPEN_POSE_DEGREES; }

    /** 'cover' | 'book' | 'flat' */
    static view(degrees) {
      if (degrees <= SHUT_DEGREES) return 'cover';
      if (degrees >= FLAT_DEGREES) return 'flat';
      return 'book';
    }

    /** The panel the view streams as its own: the cover only when shut. */
    static panel(degrees) {
      return BookPose.view(degrees) === 'cover' ? 'primary' : 'secondary';
    }

    /** Each half's turn about the crease, degrees; positive rotateY brings
     *  an element's left edge forward. */
    static leaves(degrees) {
      const fold = Math.max(0, Math.min(180, 180 - degrees));
      const share = Math.max(0, Math.min(1, degrees / OPEN_POSE_DEGREES));
      const right = -(fold / 2) * share;
      return { left: r2(fold + right), right: r2(right) };
    }

    /** The crease line's opacity: a hairline flat, deeper as it bends. */
    static creaseOpacity(degrees) {
      const fold = Math.max(0, Math.min(180, 180 - degrees));
      return r2(CREASE_FLAT + (CREASE_SHUT - CREASE_FLAT) * fold / 180);
    }

    /** Sideways shift, px, that keeps the folding book centred where the
     *  flat device was; `halfWidth` is one half's width. */
    static shift(degrees, halfWidth) {
      const { left, right } = BookPose.leaves(degrees);
      const rad = (d) => d * Math.PI / 180;
      const xs = [0, -halfWidth * Math.cos(rad(left)), halfWidth * Math.cos(rad(right))];
      return r2(-(Math.min(...xs) + Math.max(...xs)) / 2);
    }
  }

  root.Baguette = root.Baguette || {};
  root.Baguette.BookPose = BookPose;
})(window);
