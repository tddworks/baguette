// FoldBar — Device Hub's pose bar for a foldable: shut, open (its 130°
// book pose) and flat, then the hinge slider. A pick sweeps the device's
// own hinge there; the slider puts it where the thumb is as it is
// dragged. The pose nearest the hinge lights up and the slider tracks
// the hinge whenever nobody holds it.
(function (root) {
  'use strict';

  const POSES = [
    { id: 'shut', degrees: 0, label: 'Closed' },
    { id: 'open', degrees: 130, label: 'Open' },
    { id: 'flat', degrees: 180, label: 'Flat' },
  ];

  // The slider sends at most this often while dragged.
  const DRAG_INTERVAL_MS = 40;

  class FoldBar {
    static get POSES() { return POSES; }

    static nearest(degrees) {
      return POSES.reduce((a, b) =>
        Math.abs(b.degrees - degrees) < Math.abs(a.degrees - degrees) ? b : a).id;
    }

    constructor({ send, schedule } = {}) {
      this.send = send || (() => {});
      this.schedule = schedule || ((fn, ms) => setTimeout(fn, ms));
      this.active = null;
      this.sliderValue = null;
      this.held = false;
      this.dragging = null;
      this.pending = false;
      this.lastSent = null;
      this.el = null;
    }

    pick(id) {
      const pose = POSES.find((p) => p.id === id);
      if (pose) this.send({ type: 'set_pose', hingeDegrees: pose.degrees });
    }

    drag(degrees) {
      this.held = true;
      this.dragging = degrees;
      this.sliderValue = degrees;
      if (this.pending) return;
      this.pending = true;
      this.schedule(() => { this.pending = false; this.pushThumb(); }, DRAG_INTERVAL_MS);
    }

    release(degrees) {
      this.held = false;
      this.dragging = degrees;
      if (!this.pending) this.pushThumb();
    }

    pushThumb() {
      const degrees = this.dragging;
      if (degrees == null || degrees === this.lastSent) return;
      this.lastSent = degrees;
      this.send({ type: 'set_pose', hingeDegrees: degrees, duration: 0 });
    }

    /** The hinge's reading: light the nearest pose, move the free slider. */
    show(hingeDegrees) {
      const degrees = Number(hingeDegrees);
      if (!Number.isFinite(degrees)) return;
      this.active = FoldBar.nearest(degrees);
      if (!this.held) this.sliderValue = Math.round(degrees);
      this.render();
    }

    /** Builds the bar into `container`; `className` places it. */
    mount(container, { className = '', glyph } = {}) {
      this.detach();
      const el = document.createElement('div');
      el.className = ('fold-bar ' + className).trim();
      el.setAttribute('aria-label', 'Pose');
      for (const pose of POSES) {
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.dataset.pose = pose.id;
        btn.title = pose.label;
        btn.setAttribute('aria-label', pose.label);
        btn.innerHTML = glyph ? glyph(pose.id) : FoldBar.glyph(pose.id);
        btn.addEventListener('click', () => this.pick(pose.id));
        el.appendChild(btn);
      }
      const slider = document.createElement('input');
      slider.type = 'range';
      slider.min = '0'; slider.max = '180'; slider.step = '1';
      slider.dataset.role = 'hinge-slider';
      slider.title = 'Hinge angle';
      slider.setAttribute('aria-label', 'Hinge angle');
      const release = () => { if (this.held) this.release(Number(slider.value)); };
      slider.addEventListener('pointerdown', () => { this.held = true; });
      slider.addEventListener('input', () => this.drag(Number(slider.value)));
      slider.addEventListener('pointerup', release);
      slider.addEventListener('pointercancel', release);
      slider.addEventListener('change', release);
      el.appendChild(slider);
      container.appendChild(el);
      this.el = el;
      this.render();
      return el;
    }

    detach() {
      if (this.el) this.el.remove();
      this.el = null;
    }

    render() {
      if (!this.el) return;
      if (this.active) this.el.dataset.active = this.active;
      this.el.querySelectorAll('[data-pose]').forEach((btn) => {
        btn.classList.toggle('active', btn.dataset.pose === this.active);
      });
      const slider = this.el.querySelector('[data-role="hinge-slider"]');
      if (slider && !this.held && this.sliderValue != null) slider.value = String(this.sliderValue);
    }

    static glyph(id) {
      const base = 'width="20" height="16" viewBox="0 0 20 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"';
      if (id === 'shut') {
        return '<svg ' + base + '><rect x="6.5" y="1" width="7" height="14" rx="2"/></svg>';
      }
      if (id === 'open') {
        return '<svg ' + base + '><path d="M2.5 3.5 L10 1.5 L17.5 3.5 V13.5 L10 14.5 L2.5 13.5 Z"/><path d="M10 1.5 V14.5"/></svg>';
      }
      return '<svg ' + base + '><rect x="1.5" y="2" width="17" height="12" rx="2"/></svg>';
    }
  }

  root.Baguette = root.Baguette || {};
  root.Baguette.FoldBar = FoldBar;
})(window);
