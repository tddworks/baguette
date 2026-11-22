// A turned device's frame, drawn rotated: each step of its cycle a quarter
// turn clockwise, always forward, so the CSS transition never spins back
// the long way; `data-orientation` on the frame says which way it faces
// (portrait: none). A panel that arrives already turned (a foldable's
// unfolded one) is set straight without animating. What it needs of the
// page: { frame() — the device frame, cycle, laidOut() — after each turn }.
// The device's own turning is its family's (`device.orientation.turn`).

const CANONICAL = { 'portrait': 0, 'landscape-left': 90, 'portrait-upside-down': 180, 'landscape-right': 270 };

export function rotationView({ frame, cycle, laidOut }) {
  let current = 'portrait';
  let index = 0;
  let degrees = 0;

  function mark(root, value) {
    if (value === 'portrait') root.removeAttribute('data-orientation');
    else root.setAttribute('data-orientation', value);
  }

  return {
    get current() { return current; },

    /** The orientation one step on in the cycle (the frame isn't drawn yet). */
    next() {
      index = (index + 1) % cycle.length;
      return cycle[index];
    },

    /** Start the cycle at `value`, the frame drawn later (a foldable's lit panel). */
    startAt(value) {
      current = value;
      index = Math.max(0, cycle.indexOf(value));
    },

    /** Draw the frame turned to `value`, a quarter forward from where it was. */
    apply(value) {
      const previous = current;
      current = value;
      const root = frame();
      if (root) {
        mark(root, value);
        if (value !== previous) degrees += 90;
        for (const wrapper of root.querySelectorAll(':scope > div')) {
          wrapper.style.transform = 'rotate(' + degrees + 'deg)';
        }
      }
      laidOut();
    },

    /** Set `value` outright, no step and no animation. */
    snap(value) {
      current = value;
      degrees = CANONICAL[value] || 0;
      index = Math.max(0, cycle.indexOf(value));
      const root = frame();
      if (root) {
        mark(root, value);
        for (const wrapper of root.querySelectorAll(':scope > div')) {
          const transition = wrapper.style.transition;
          wrapper.style.transition = 'none';
          wrapper.style.transform = 'rotate(' + degrees + 'deg)';
          void wrapper.offsetWidth;
          wrapper.style.transition = transition;
        }
      }
      laidOut();
    },
  };
}

if (typeof window !== 'undefined') {
  window.Baguette = window.Baguette || {};
  window.Baguette._RotationView = { rotationView };
}
