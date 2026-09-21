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
      // The screen's shape: the simulator's own framebuffer mask when
      // the definition names one — iPhone Duo's cover is near-square
      // on the hinge side and round on the outer edge, which one
      // radius cannot say — otherwise `clipRadius` on every corner.
      const cr = this.def.clipRadius || 0;
      const hPct = (cr / r.width)  * 100;
      const vPct = (cr / r.height) * 100;
      screenArea.style.borderRadius = `${hPct}% / ${vPct}%`;
      if (this.def.maskImage) {
        const mask = `url("${this.def.maskImage}") center / 100% 100% no-repeat`;
        screenArea.style.webkitMaskImage = `url("${this.def.maskImage}")`;
        screenArea.style.webkitMaskSize = '100% 100%';
        screenArea.style.webkitMaskRepeat = 'no-repeat';
        screenArea.style.maskImage = `url("${this.def.maskImage}")`;
        screenArea.style.maskSize = '100% 100%';
        screenArea.style.maskRepeat = 'no-repeat';
        screenArea.style.borderRadius = '0';
        void mask;
      }

      // A foldable's unfolded panel is one framebuffer creased by the
      // hinge across the middle of its long axis. Device Hub draws the
      // seam; so does this — a hairline over the frame, no input.
      if (this.def.crease) {
        const crease = document.createElement('div');
        const tall = r.height >= r.width;
        crease.dataset.crease = '';
        crease.style.cssText = [
          'position:absolute', 'pointer-events:none', 'z-index:3',
          tall ? 'left:0;right:0;top:50%;height:1px;transform:translateY(-50%)'
               : 'top:0;bottom:0;left:50%;width:1px;transform:translateX(-50%)',
          'background:rgba(0,0,0,0.05)',
        ].join(';');
        screenArea.appendChild(crease);
      }

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
