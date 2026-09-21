// BookPose — how the flat view draws a foldable at a hinge angle, posed
// as the server's `FoldPose` poses the 3D model.
(function (root) {
  'use strict';

  // Device Hub's closed pose reads ≈3°, its open pose 130°.
  const SHUT_DEGREES = 5;
  const FLAT_DEGREES = 178;
  const OPEN_POSE_DEGREES = 130;
  const CREASE_FLAT = 0.05;
  const CREASE_SHUT = 0.25;
  // Shares of the unfolded device's width: each half's thickness, the viewer's distance.
  const THICKNESS = 0.024;
  const PERSPECTIVE = 3;

  // How much taller than flat the book looks: a half's outer edge comes toward the viewer.
  function magnification(degrees) {
    const { left, right } = BookPose.leaves(degrees);
    const sin = (d) => Math.max(0, Math.sin(d * Math.PI / 180));
    const near = 0.5 * Math.max(sin(left), sin(-right)) + THICKNESS;
    return PERSPECTIVE / (PERSPECTIVE - near);
  }

  const r2 = (v) => Math.round(v * 100) / 100 || 0;   // no -0

  class BookPose {
    static get OPEN_POSE_DEGREES() { return OPEN_POSE_DEGREES; }
    static get THICKNESS() { return THICKNESS; }
    static get PERSPECTIVE() { return PERSPECTIVE; }

    static magnification(degrees) { return magnification(degrees); }

    /** Room kept round the flat device so the open pose fills the box. */
    static get RESERVE() { return magnification(OPEN_POSE_DEGREES); }

    /** Scales a pose that would bulge past the box back into it. */
    static stageScale(degrees) {
      return Math.min(1, BookPose.RESERVE / magnification(degrees));
    }

    /** 'cover' | 'book' | 'flat' */
    static view(degrees) {
      if (degrees <= SHUT_DEGREES) return 'cover';
      if (degrees >= FLAT_DEGREES) return 'flat';
      return 'book';
    }

    /** The book is the unfolded panel, so only shut streams the cover. */
    static panel(degrees) {
      return BookPose.view(degrees) === 'cover' ? 'primary' : 'secondary';
    }

    /** Each half's rotateY about the crease; the left half folds over the right. */
    static leaves(degrees) {
      const fold = Math.max(0, Math.min(180, 180 - degrees));
      const share = Math.max(0, Math.min(1, degrees / OPEN_POSE_DEGREES));
      const right = -(fold / 2) * share;
      return { left: r2(fold + right), right: r2(right) };
    }

    static creaseOpacity(degrees) {
      const fold = Math.max(0, Math.min(180, 180 - degrees));
      return r2(CREASE_FLAT + (CREASE_SHUT - CREASE_FLAT) * fold / 180);
    }

    /** Unrotated size and offset, px, that contain the device in `box` once turned. */
    static fitDevice(box, aspect, rotation) {
      const turned = (((rotation % 360) + 360) % 360) % 180 !== 0;
      const shown = turned ? 1 / aspect : aspect;
      let vw = box.width, vh = box.width / shown;
      if (vh > box.height) { vh = box.height; vw = box.height * shown; }
      const width = r2(turned ? vh : vw), height = r2(turned ? vw : vh);
      return {
        width, height,
        left: r2((box.width - width) / 2), top: r2((box.height - height) / 2),
      };
    }

    /** How far the cover, drawn at its own shape, overhangs each side of its half. */
    static coverOverhang(halfWidth, height, coverAspect) {
      return (height * coverAspect - halfWidth) / 2;
    }

    /** Sideways shift, px, that keeps the folding book centred. */
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
