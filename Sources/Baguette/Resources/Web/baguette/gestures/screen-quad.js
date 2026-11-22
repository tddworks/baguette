// ScreenQuad — where the device screen mesh lands in a rendered 3D frame,
// answering "where does this point land within me?" for itself. Pure
// perspective-quad math (no DOM/canvas ownership beyond
// `getBoundingClientRect` for the static content-rect helper), so it can
// be driven by PointerInterpreter or Sim3DPanel without either owning it.

function crossXY(a, b) {
  return a.x * b.y - a.y * b.x;
}

class ScreenQuad {
  constructor(topLeft, topRight, bottomRight, bottomLeft) {
    this.topLeft = topLeft;
    this.topRight = topRight;
    this.bottomRight = bottomRight;
    this.bottomLeft = bottomLeft;
  }

  /** Server wire shape `[[x,y],[x,y],[x,y],[x,y]]` (TL,TR,BR,BL) → quad, or null if malformed. */
  static fromCorners(corners) {
    if (!Array.isArray(corners) || corners.length !== 4) return null;
    const [topLeft, topRight, bottomRight, bottomLeft] = corners;
    return new ScreenQuad(
        { u: topLeft[0], v: topLeft[1] },
        { u: topRight[0], v: topRight[1] },
        { u: bottomRight[0], v: bottomRight[1] },
        { u: bottomLeft[0], v: bottomLeft[1] },
    );
  }

  // The canvas's CSS box may be larger than its drawn content when
  // `object-fit: contain` letterboxes the backing store inside it —
  // this finds the actual drawn (content) rect so client coordinates
  // line up with quad corners normalized to the rendered frame.
  static contentRect(canvas) {
    const box = canvas.getBoundingClientRect();
    const contentAspect = canvas.width / canvas.height;
    const boxAspect = box.width / box.height;
    let width, height;
    if (contentAspect > boxAspect) {
      width = box.width;
      height = box.width / contentAspect;
    } else {
      height = box.height;
      width = box.height * contentAspect;
    }
    return {
      left: box.left + (box.width - width) / 2,
      top: box.top + (box.height - height) / 2,
      width,
      height,
    };
  }

  static mapClientPointFromContain(canvas, clientX, clientY, size) {
    const rect = ScreenQuad.contentRect(canvas);
    if (!rect.width || !rect.height) {
      return { x: 0, y: 0, xNorm: 0, yNorm: 0, inside: false };
    }
    const xNorm = (clientX - rect.left) / rect.width;
    const yNorm = (clientY - rect.top) / rect.height;
    const inside = xNorm >= 0 && xNorm <= 1 && yNorm >= 0 && yNorm <= 1;
    const { width, height } = size;
    return {
      x: xNorm * width,
      y: yNorm * height,
      xNorm,
      yNorm,
      inside,
    };
  }

  /**
   * Solves for (u,v) in [0,1]×[0,1] such that bilinear interpolation
   * of my four corners at (u,v) lands on (px,py) — the inverse of the
   * forward map that placed the corners. `inside` is false when
   * (px,py) falls outside the quad (bezel/body/background around the
   * rendered screen).
   */
  locate(px, py) {
    const a = this.topLeft, b = this.topRight;
    const c = this.bottomRight, d = this.bottomLeft;
    const e = { x: b.u - a.u, y: b.v - a.v };
    const f = { x: d.u - a.u, y: d.v - a.v };
    const g = { x: a.u - b.u - d.u + c.u, y: a.v - b.v - d.v + c.v };
    const h = { x: px - a.u, y: py - a.v };

    const qa = crossXY(g, f);
    const qb = crossXY(e, f) + crossXY(h, g);
    const qc = crossXY(h, e);

    let v;
    if (Math.abs(qa) < 1e-9) {
      v = Math.abs(qb) < 1e-9 ? 0 : -qc / qb;
    } else {
      const discriminant = qb * qb - 4 * qa * qc;
      if (discriminant < 0) return { u: 0.5, v: 0.5, inside: false };
      const sqrtDiscriminant = Math.sqrt(discriminant);
      const v1 = (-qb + sqrtDiscriminant) / (2 * qa);
      const v2 = (-qb - sqrtDiscriminant) / (2 * qa);
      const inRange = (value) => value >= -0.001 && value <= 1.001;
      if (inRange(v1) && !inRange(v2)) v = v1;
      else if (inRange(v2) && !inRange(v1)) v = v2;
      else v = Math.abs(v1 - 0.5) <= Math.abs(v2 - 0.5) ? v1 : v2;
    }

    const denomX = e.x + v * g.x;
    const denomY = e.y + v * g.y;
    const u = Math.abs(denomX) >= Math.abs(denomY)
      ? (h.x - v * f.x) / denomX
      : (h.y - v * f.y) / denomY;

    // A small epsilon so a click landing right at the visual edge —
    // exactly what edge-band gestures target — doesn't get rejected
    // by floating-point noise from the quadratic solve.
    const epsilon = 0.001;
    const inside = u >= -epsilon && u <= 1 + epsilon && v >= -epsilon && v <= 1 + epsilon;
    return { u, v, inside };
  }
}

export { ScreenQuad };

