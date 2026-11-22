// ScreenPieces — where the lit screen lands in a rendered 3D frame, as
// the server's `screen_quad` names it: one quad for a phone, or, for a
// foldable whose unfolded screen bends at the hinge, flat pieces that
// each carry the part of the framebuffer they show. A click maps
// through whichever piece it lands on straight into framebuffer space,
// so the page needs no orientation of its own.
import { ScreenQuad } from './screen-quad.js';

class ScreenPieces {
  /** @param {Array<{quad, u:[number,number], v:[number,number]}>} pieces */
  constructor(pieces) {
    this.pieces = pieces || [];
  }

  get length() { return this.pieces.length; }

  /** From a `screen_quad` envelope: `pieces`, else `corners`. */
  static fromMessage(envelope) {
    if (!envelope) return new ScreenPieces([]);
    if (Array.isArray(envelope.pieces)) {
      const pieces = envelope.pieces.map((p) => {
        const quad = p && ScreenQuad.fromCorners(p.corners);
        const range = (r) => (Array.isArray(r) && r.length === 2 ? r : [0, 1]);
        return quad ? { quad, u: range(p.u), v: range(p.v) } : null;
      }).filter(Boolean);
      return new ScreenPieces(pieces);
    }
    const quad = ScreenQuad.fromCorners(envelope.corners);
    return new ScreenPieces(quad ? [{ quad, u: [0, 1], v: [0, 1] }] : []);
  }

  /** Frame point (normalized) → framebuffer point (normalized). Off
   *  every piece, the point is still placed — clamped onto the first
   *  piece — so a drag that leaves the screen keeps a position. */
  locate(px, py) {
    let fallback = { u: 0, v: 0, inside: false };
    for (const [index, piece] of this.pieces.entries()) {
      const hit = piece.quad.locate(px, py);
      const placed = {
        u: piece.u[0] + Math.max(0, Math.min(1, hit.u)) * (piece.u[1] - piece.u[0]),
        v: piece.v[0] + Math.max(0, Math.min(1, hit.v)) * (piece.v[1] - piece.v[0]),
        inside: !!hit.inside,
      };
      if (placed.inside) return placed;
      if (index === 0) fallback = placed;
    }
    return fallback;
  }
}

export { ScreenPieces };

