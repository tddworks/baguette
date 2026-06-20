// Button — one hardware button as a domain object. Knows its
// envelope (set by the Swift definition), its images, its z-order;
// renders its own DOM overlay; emits a press through Transport on
// mouseup. The view layer never sees `{type:"button",...}`; it
// just calls `button.press({hold})`.
//
// Animation policy: at-rest → hover (pop outward) → pressed (recede
// inward). Today's implementation is a placeholder transform — the
// definition will later carry pre-computed transform CSS; the
// renderer interpolates between rest/pressed sprites and a small
// translate for hover/press feedback.
(function (root) {
  'use strict';

  class Button {
    /**
     * @param {object}    def        SimulatorDefinition.buttons[*]
     * @param {Transport} transport
     */
    constructor(def, transport) {
      this.def = def;
      this.transport = transport;
      this.id = def.id;
      this.element = null;
    }

    /** Public domain verb. Hold is seconds. */
    press({ hold = 0 } = {}) {
      this.transport.button(this.def.envelope, { hold });
    }

    /** Render this button into `wrapper`. Returns the created element. */
    mount(wrapper) {
      const wire = this.def.envelope.button;
      const box  = this.def.box;
      const tf   = this.def.transform;
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.dataset.btn = this.id;
      btn.title = humanize(this.id) + ' → ' + wire;
      btn.setAttribute('aria-label', btn.title);
      // Z-order: 'below' pokes through a transparent slot in the
      // bezel (every iPhone hardware button); 'above' renders on top
      // (Apple Watch action cap). The bezel image sits at z:1 in
      // bezel.js, so below=0 / above=2 lines up with that.
      const z = this.def.z === 'above' ? 2 : 0;
      btn.style.cssText = [
        'position:absolute',
        `left:${box.leftPct}%`,
        `top:${box.topPct}%`,
        `width:${box.widthPct}%`,
        `height:${box.heightPct}%`,
        'padding:0', 'border:0', 'background:transparent',
        'cursor:pointer',
        `z-index:${z}`,
        'transition:transform 160ms cubic-bezier(0.2, 0.7, 0.2, 1.0)',
        '-webkit-user-select:none', 'user-select:none',
      ].join(';');
      if (tf.rest && tf.rest !== 'none') btn.style.transform = tf.rest;

      const img = new Image();
      img.src = this.def.images.rest;
      img.draggable = false;
      img.alt = '';
      img.style.cssText = 'display:block;pointer-events:none;width:100%;height:100%';
      btn.appendChild(img);
      // Pre-fetch the pressed sprite so the swap is instant.
      if (this.def.images.pressed !== this.def.images.rest) {
        const pre = new Image(); pre.src = this.def.images.pressed;
      }

      const applyTransform = (key) => {
        if (key === 'rest' && (!tf.rest || tf.rest === 'none')) {
          btn.style.transform = '';
        } else {
          btn.style.transform = tf[key] || '';
        }
      };

      let pressedAt = 0;
      btn.addEventListener('mouseenter', () => applyTransform('hover'));
      btn.addEventListener('mousedown', () => {
        pressedAt = performance.now();
        applyTransform('pressed');
        if (this.def.images.pressed !== this.def.images.rest) {
          img.src = this.def.images.pressed;
        }
      });
      btn.addEventListener('mouseup', (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        applyTransform('hover');
        img.src = this.def.images.rest;
        if (!pressedAt) return;
        const seconds = (performance.now() - pressedAt) / 1000;
        pressedAt = 0;
        this.press({ hold: seconds });
      });
      btn.addEventListener('mouseleave', () => {
        pressedAt = 0;
        applyTransform('rest');
        img.src = this.def.images.rest;
      });
      btn.addEventListener('click', (ev) => {
        // Synthetic clicks fire after mouseup — we already pressed.
        ev.preventDefault(); ev.stopPropagation();
      });

      wrapper.appendChild(btn);
      this.element = btn;
      return btn;
    }

    detach() {
      if (this.element && this.element.parentNode) {
        this.element.parentNode.removeChild(this.element);
      }
      this.element = null;
    }
  }

  function humanize(name) {
    return name.replace(/([A-Z])/g, ' $1').replace(/^./, c => c.toUpperCase()).trim();
  }

  root.Baguette = root.Baguette || {};
  root.Baguette._Button = Button;
})(window);
