// Bezel — renders the device chrome (outer body + clipped screen
// rect) from the SDK definition. Pure DOM construction; no input
// handling, no wire format. Owned by Simulator; never instantiated
// by consumers directly.
//
// Mounts under a wrapper element styled `position:relative` so
// every other part (buttons, screen, overlays) can position
// absolutely against it.
(function (root) {
  'use strict';

  class Bezel {
    /**
     * @param {object} screenDef  SimulatorDefinition.screen
     * @param {object} [opts]
     * @param {boolean} [opts.bare]  fetch buttons-stripped bezel
     *   (true when Buttons are rendered as overlays — the default
     *   for Baguette.use, since the SDK always overlays buttons).
     */
    constructor(screenDef, { bare = true } = {}) {
      this.def = screenDef;
      this.bare = bare;
      this.wrapper = null;
      this.frameImg = null;
      this.screenArea = null;
      this.canvas = null;
    }

    mount(container) {
      container.innerHTML = '';
      const wrapper = document.createElement('div');
      // `dvh` (dynamic viewport height) subtracts iOS Safari's URL bar
      // and bottom toolbar from the cap, so the bezel doesn't render
      // behind them and get clipped. The earlier `vh` declaration
      // stays as a fallback for engines without `dvh` support.
      wrapper.style.cssText =
        'position:relative;display:inline-block;max-height:70vh;max-height:70dvh;';

      const frameImg = document.createElement('img');
      frameImg.src = this.bare ? this.def.bezelImage.bare : this.def.bezelImage.rest;
      frameImg.draggable = false;
      frameImg.alt = '';
      frameImg.style.cssText =
        'display:block;height:100%;max-height:70vh;max-height:70dvh;pointer-events:none;position:relative;z-index:1;';
      frameImg.onerror = () => { frameImg.style.display = 'none'; };

      const screenArea = document.createElement('div');
      screenArea.style.cssText =
        'position:absolute;overflow:hidden;cursor:crosshair;z-index:2;';
      screenArea.tabIndex = 0;
      screenArea.style.outline = 'none';

      const canvas = document.createElement('canvas');
      canvas.id = 'simStreamCanvas';
      canvas.style.cssText =
        'display:block;width:100%;height:100%;object-fit:fill;image-rendering:high-quality;';
      screenArea.appendChild(canvas);

      wrapper.appendChild(screenArea);
      wrapper.appendChild(frameImg);

      // Position the screen rect inside the bezel as percentages so
      // the overlay tracks the bezel as the viewport scales.
      const vp = this.def.viewport;
      const r = this.def.rect;
      screenArea.style.left   = (r.x      / vp.width  * 100) + '%';
      screenArea.style.top    = (r.y      / vp.height * 100) + '%';
      screenArea.style.width  = (r.width  / vp.width  * 100) + '%';
      screenArea.style.height = (r.height / vp.height * 100) + '%';
      const cr = this.def.clipRadius || 0;
      const hPct = (cr / r.width)  * 100;
      const vPct = (cr / r.height) * 100;
      screenArea.style.borderRadius = `${hPct}% / ${vPct}%`;

      container.appendChild(wrapper);

      this.wrapper = wrapper;
      this.frameImg = frameImg;
      this.screenArea = screenArea;
      this.canvas = canvas;
    }

    detach() {
      if (this.wrapper && this.wrapper.parentNode) {
        this.wrapper.parentNode.removeChild(this.wrapper);
      }
      this.wrapper = null;
      this.frameImg = null;
      this.screenArea = null;
      this.canvas = null;
    }
  }

  root.Baguette = root.Baguette || {};
  root.Baguette._Bezel = Bezel;
})(window);
