// PinchOverlay — passive visual HUD showing where the synthesized
// fingers are during a pinch / pan / drag. Absolutely-positioned
// dots inside a host element; pointer-events:none so it never
// captures clicks. PointerInterpreter pushes finger positions; this
// module only draws.
(function (root) {
  'use strict';

  class PinchOverlay {
    /** @param {HTMLElement} host */
    constructor(host) {
      this.host = host;
      this.container = document.createElement('div');
      this.container.style.cssText =
        'position:absolute;inset:0;pointer-events:none;z-index:9;';
      host.appendChild(this.container);
    }

    /** @param {{x:number,y:number}[]} points  pixels, host-local */
    setFingers(points) {
      const kids = this.container.children;
      while (kids.length < points.length) this.container.appendChild(_dot());
      while (kids.length > points.length) this.container.removeChild(kids[0]);
      for (let i = 0; i < points.length; i++) {
        kids[i].style.left = points[i].x + 'px';
        kids[i].style.top  = points[i].y + 'px';
      }
    }

    clear()  { this.container.innerHTML = ''; }
    detach() {
      if (this.container.parentNode) this.container.parentNode.removeChild(this.container);
    }
  }

  function _dot() {
    const d = document.createElement('div');
    d.style.cssText = [
      'position:absolute', 'width:36px', 'height:36px',
      'margin-left:-18px', 'margin-top:-18px', 'border-radius:50%',
      'background:rgba(99,102,241,0.35)',
      'border:2px solid rgba(99,102,241,0.9)',
      'box-shadow:0 0 12px rgba(99,102,241,0.5)',
    ].join(';');
    return d;
  }

  root.Baguette = root.Baguette || {};
  root.Baguette._PinchOverlay = PinchOverlay;
})(window);
