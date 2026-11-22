// GestureEnvelope — the wire shape a tap/swipe/touch becomes, split out
// of Transport so it's testable independent of the WebSocket send/error
// plumbing. Transport owns dispatch (`_send`, error logging, screen-size
// state); GestureEnvelope only knows how to describe a gesture as JSON.

class GestureEnvelope {
  /** Only an absent edge means an interior touch, so anything else
   *  the caller named — `''` included — goes on the wire for the
   *  server to reject rather than being demoted here in silence. */
  static named(edge) {
    return edge !== undefined && edge !== null;
  }

  /** `edge` is the same screen-edge hint `touch` carries; omitted
   *  for ordinary interior taps. */
  static tap({ x, y, duration = 0.05, edge }, size) {
    const envelope = { type: 'tap', x, y, duration, ...size };
    if (GestureEnvelope.named(edge)) envelope.edge = edge;
    return envelope;
  }

  /** The pointer moving with no button down — a Mac display's hover. */
  static hover({ x, y }, size) {
    return { type: 'hover', x, y, ...size };
  }

  static swipe({ from, to, duration = 0.25 }, size) {
    return {
      type: 'swipe',
      startX: from.x, startY: from.y,
      endX: to.x, endY: to.y,
      duration,
      ...size,
    };
  }

  /**
   * @param {'down'|'move'|'up'} phase
   * @param {Array<{x:number,y:number}>} fingers  one or two touch points
   * @param {{edge?:string}|null} opts
   * @returns the envelope, or `null` when `fingers` isn't 1 or 2 long
   */
  static touch(phase, fingers, opts, size) {
    if (fingers.length === 1) {
      const envelope = { type: `touch1-${phase}`, x: fingers[0].x, y: fingers[0].y, ...size };
      if (opts && GestureEnvelope.named(opts.edge)) envelope.edge = opts.edge;
      return envelope;
    }
    if (fingers.length === 2) {
      return {
        type: `touch2-${phase}`,
        x1: fingers[0].x, y1: fingers[0].y,
        x2: fingers[1].x, y2: fingers[1].y,
        ...size,
      };
    }
    return null;
  }
}

export { GestureEnvelope };

