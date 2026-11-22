// A turned simulator is drawn rotated (CSS on its frame), so the page's input
// arrives in the frame the user sees; iOS takes portrait coordinates. Each
// envelope is turned back before it's sent — its edge flag too: iOS's gesture
// recognizers want the flag to match the touch's physical edge, or the home
// gesture never fires. The direction mirrors the CSS transforms in
// page/device-page.html (landscape-right is rotate(-90deg), so its inverse
// turns clockwise).

/** A normalized point [0, 1]² in the visual frame, in portrait. */
function normalized(x, y, orientation) {
  switch (orientation) {
    case 'landscape-right':      return { x: 1 - y, y: x };
    case 'portrait-upside-down': return { x: 1 - x, y: 1 - y };
    case 'landscape-left':       return { x: y, y: 1 - x };
    default:                     return { x, y };
  }
}

// The edge a swipe from the visual bottom comes from, physically — measured
// against iOS 26.4's home-indicator recognizer:
//   portrait              : bottom → bottom
//   landscape-left        : bottom → right
//   portrait-upside-down  : bottom → right
//   landscape-right       : bottom → top
function edge(name, orientation) {
  if (!name || name !== 'bottom') return name;
  switch (orientation) {
    case 'landscape-left':
    case 'portrait-upside-down': return 'right';
    case 'landscape-right':      return 'top';
    default:                     return name;
  }
}

/** `envelope` (wire coordinates in the visual frame) turned into portrait. */
export function toPortrait(envelope, orientation) {
  if (!envelope || !envelope.type) return envelope;
  const W = envelope.width || 0, H = envelope.height || 0;
  const turn = (x, y) => {
    if (!W || !H) return { x, y };
    const r = normalized(x / W, y / H, orientation);
    return { x: r.x * W, y: r.y * H };
  };
  switch (envelope.type) {
    case 'tap': {
      const r = turn(envelope.x, envelope.y);
      return { ...envelope, x: r.x, y: r.y };
    }
    case 'swipe': {
      const a = turn(envelope.startX, envelope.startY), b = turn(envelope.endX, envelope.endY);
      return { ...envelope, startX: a.x, startY: a.y, endX: b.x, endY: b.y };
    }
    case 'touch1-down':
    case 'touch1-move':
    case 'touch1-up': {
      const r = turn(envelope.x, envelope.y);
      const out = { ...envelope, x: r.x, y: r.y };
      if (envelope.edge) out.edge = edge(envelope.edge, orientation);
      return out;
    }
    case 'touch2-down':
    case 'touch2-move':
    case 'touch2-up': {
      const a = turn(envelope.x1, envelope.y1), b = turn(envelope.x2, envelope.y2);
      return { ...envelope, x1: a.x, y1: a.y, x2: b.x, y2: b.y };
    }
    default:
      return envelope;
  }
}

if (typeof window !== 'undefined') {
  window.Baguette = window.Baguette || {};
  window.Baguette._Portrait = { toPortrait };
}
