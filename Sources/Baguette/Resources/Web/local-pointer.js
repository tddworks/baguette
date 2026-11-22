// LocalPointer — a Mac display's pointer, drawn by the page the moment the
// hand moves. The Mac's own pointer is left out of its stream (it would trail
// the hand by the whole round trip); a mouse or trackpad shows the browser's
// own arrow, and a finger or pen gets one drawn where it touches. Clicks
// still go to the Mac as before — only the pointer is local.
(function (root) {
  'use strict';

  // A macOS-like arrow, its tip at the hotspot (0,0).
  const ARROW =
    '<svg width="18" height="26" viewBox="0 0 18 26" xmlns="http://www.w3.org/2000/svg">' +
    '<path d="M1 1 L1 21 L6 16.5 L9.5 24.5 L13 23 L9.6 15.2 L16 15.2 Z" ' +
    'fill="#000" stroke="#fff" stroke-width="1.5" stroke-linejoin="round"/></svg>';

  const LocalPointer = {
    /** Where a pointer at `event` sits on `screen` (its rect), in percent, kept on the screen. */
    place(event, screen) {
      const clamp = (v) => Math.max(0, Math.min(100, v));
      return {
        left: clamp((event.clientX - screen.left) / screen.width * 100),
        top: clamp((event.clientY - screen.top) / screen.height * 100),
      };
    },

    /** Whether the page draws the pointer for this kind of pointer: a mouse has its own. */
    draws(pointerType) {
      return pointerType === 'touch' || pointerType === 'pen';
    },

    /** Over `screenArea`: the browser's arrow for a mouse, a drawn one for a finger. */
    attach(screenArea) {
      screenArea.style.cursor = 'default';
      const arrow = document.createElement('div');
      arrow.innerHTML = ARROW;
      arrow.style.cssText = 'position:absolute;left:50%;top:50%;width:18px;height:26px;' +
          'pointer-events:none;z-index:5;display:none;filter:drop-shadow(0 1px 1px rgba(0,0,0,.35))';
      screenArea.appendChild(arrow);
      const follow = (e) => {
        if (!LocalPointer.draws(e.pointerType)) { arrow.style.display = 'none'; return; }
        const at = LocalPointer.place(e, screenArea.getBoundingClientRect());
        arrow.style.left = at.left + '%';
        arrow.style.top = at.top + '%';
        arrow.style.display = 'block';
      };
      ['pointerdown', 'pointermove'].forEach((type) =>
        screenArea.addEventListener(type, follow, { passive: true }));
      return { detach() { arrow.remove(); } };
    },
  };

  root.Baguette = root.Baguette || {};
  root.Baguette._LocalPointer = LocalPointer;
})(window);
