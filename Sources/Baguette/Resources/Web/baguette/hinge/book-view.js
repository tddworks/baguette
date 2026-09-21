// BookView — a foldable drawn as a book from its 2D frames: the flat
// view's unfolded device (bezel + live stream, masked, creased) split at
// the crease into two halves hinged in perspective, posed by `BookPose`.
// The left half is two-faced: the live cover is on its back, so shutting
// the book turns the cover toward the viewer.
//
// Clicks on the tilted halves land where they look: each half carries
// 1×1 markers at the screen's corners, the browser projects them, and
// `mapClientPoint` inverts the projected quad (`ScreenQuad.locate`).
// Integration-only: DOM and canvas.
(function (root) {
  'use strict';

  // Each half's thickness as a share of the whole device's width, and
  // the resolution its rim slices are drawn at (an edge, never read).
  const THICKNESS = 0.024;
  const RIM_SCALE = 0.5;
  // The rim catches the light at the front and falls off to the back.
  const RIM_FRONT = [92, 92, 97];
  const RIM_BACK = [28, 28, 31];

  function loadImage(src) {
    if (!src) return null;
    const img = new Image();
    img.src = src;
    return img;
  }
  const ready = (img) => !!(img && img.complete && img.naturalWidth);

  // Bezel, screen (masked or rounded) and crease (its opacity, or 0)
  // into `scratch`, W × H CSS px in the device's own unrotated layout.
  function compose(scratch, W, H, dpr, { bezel, frame, screen, mask, crease }) {
    const w = Math.max(1, Math.round(W * dpr)), h = Math.max(1, Math.round(H * dpr));
    if (scratch.width !== w || scratch.height !== h) { scratch.width = w; scratch.height = h; }
    const sc = scratch.getContext('2d');
    sc.setTransform(dpr, 0, 0, dpr, 0, 0);
    sc.clearRect(0, 0, W, H);
    if (ready(bezel)) sc.drawImage(bezel, 0, 0, W, H);
    const vp = screen.viewport, r = screen.rect;
    const sx = r.x / vp.width * W, sy = r.y / vp.height * H;
    const sw = r.width / vp.width * W, sh = r.height / vp.height * H;
    const f = scratch._frame || (scratch._frame = document.createElement('canvas'));
    const fw = Math.max(1, Math.round(sw * dpr)), fh = Math.max(1, Math.round(sh * dpr));
    if (f.width !== fw || f.height !== fh) { f.width = fw; f.height = fh; }
    const fc = f.getContext('2d');
    fc.setTransform(dpr, 0, 0, dpr, 0, 0);
    fc.globalCompositeOperation = 'source-over';
    fc.fillStyle = '#000';
    fc.fillRect(0, 0, sw, sh);
    if (frame && frame.width && frame.height) fc.drawImage(frame, 0, 0, sw, sh);
    if (crease) {
      fc.fillStyle = `rgba(0,0,0,${crease})`;
      if (sh >= sw) fc.fillRect(0, sh / 2 - 0.5, sw, 1);
      else          fc.fillRect(sw / 2 - 0.5, 0, 1, sh);
    }
    if (ready(mask)) {
      fc.globalCompositeOperation = 'destination-in';
      fc.drawImage(mask, 0, 0, sw, sh);
      sc.drawImage(f, sx, sy, sw, sh);
    } else {
      sc.save();
      const cr = (screen.clipRadius || 0) / vp.width * W;
      sc.beginPath();
      sc.roundRect(sx, sy, sw, sh, cr);
      sc.clip();
      sc.drawImage(f, sx, sy, sw, sh);
      sc.restore();
    }
  }

  class BookView {
    /**
     * @param {object} front  `{ wrapper, canvas, screenArea, screen }` — the
     *   flat view's mounted unfolded device and its definition.screen
     * @param {object} back   `{ canvas, screen }` — the live cover feed
     * @param {number} rotation  the page's CSS rotation of `wrapper`, degrees
     * @param {object} [opts]  `onMount(stage)` — each time the stage is
     *   built, so input can be bound to it
     */
    constructor(front, back, rotation, { onMount } = {}) {
      this.front = front;
      this.back = back;
      this.onMount = onMount || null;
      this.host = null;
      this.rotation = ((rotation % 360) + 360) % 360;
      this.frontImgs = {
        bezel: front.wrapper.querySelector(':scope > img'),
        mask: loadImage(front.screen.maskImage),
      };
      this.backImgs = back ? {
        bezel: loadImage(back.screen.bezelImage && back.screen.bezelImage.bare),
        mask: loadImage(back.screen.maskImage),
      } : null;
      this.scratch = document.createElement('canvas');
      this.backScratch = document.createElement('canvas');
      this.stage = null;
      this.leaves = null;
      this.raf = null;
      this.degrees = 180;
      this.dpr = window.devicePixelRatio || 1;
      this._onResize = () => { if (this.stage) { this._unmount(); this.show(this.degrees); } };
    }

    /** Only a vertical crease folds as a book on the page. */
    static canFold(rotation) {
      return (((rotation % 360) + 360) % 360) % 180 === 90;
    }

    show(degrees) {
      this.degrees = degrees;
      if (this.disposed) return;
      if (!this.stage && !this._mount()) {
        // A device just mounted has no size until its bezel loads; try
        // again next frame rather than wait for the next hinge sample.
        if (!this.retry) {
          this.retry = requestAnimationFrame(() => { this.retry = 0; this.show(this.degrees); });
        }
        return;
      }
      const a = root.Baguette.BookPose.leaves(degrees);
      this.leafAngles = a;
      this.leaves.left.el.style.transform = `rotateY(${a.left}deg)`;
      this.leaves.right.el.style.transform = `rotateY(${a.right}deg)`;
      // Past the crease the left half lies over the right one.
      this.leaves.left.el.style.zIndex = a.left > 90 ? '2' : '1';
      const shift = root.Baguette.BookPose.shift(degrees, this.halfW);
      this.stage.style.transform = `translateX(${shift}px)`;
      if (!this.raf) this._tick();
    }

    /** Stop redrawing; the halves keep their last frame. */
    freeze() {
      if (this.raf) { cancelAnimationFrame(this.raf); this.raf = null; }
      this.frozen = true;
    }

    /** Fade the stage out over `ms` onto whatever the page now shows. */
    fadeOut(ms) {
      if (!this.stage) return;
      this.freeze();
      window.removeEventListener('resize', this._onResize);
      if (this.host) this.host.style.visibility = '';
      const stage = this.stage;
      stage.style.pointerEvents = 'none';
      stage.style.transition = `opacity ${ms}ms ease`;
      stage.style.opacity = '0';
      setTimeout(() => this.dispose(), ms);
    }

    dispose() {
      this.disposed = true;
      if (this.retry) { cancelAnimationFrame(this.retry); this.retry = 0; }
      this.freeze();
      this._unmount();
    }

    _unmount() {
      window.removeEventListener('resize', this._onResize);
      if (this.stage) { this.stage.remove(); this.stage = null; this.leaves = null; }
      if (this.host) this.host.style.visibility = '';
    }

    _mount() {
      const wrapper = this.front.wrapper;
      const rect = wrapper.getBoundingClientRect();
      if (rect.width < 10 || rect.height < 10) return false;
      const sr = this.front.screenArea.getBoundingClientRect();
      const screenBox = {
        left: sr.left - rect.left, top: sr.top - rect.top, width: sr.width, height: sr.height,
      };
      const halfW = rect.width / 2, H = rect.height;
      const stage = document.createElement('div');
      stage.style.cssText = [
        'position:fixed', `left:${rect.left}px`, `top:${rect.top}px`,
        `width:${rect.width}px`, `height:${H}px`,
        'z-index:30', 'perspective:1600px', 'perspective-origin:50% 50%',
        'cursor:crosshair', 'touch-action:none', 'user-select:none', '-webkit-user-select:none',
      ].join(';');
      const marker = (x, y) => {
        const m = document.createElement('div');
        m.style.cssText = `position:absolute;left:${x}px;top:${y}px;width:1px;height:1px;pointer-events:none;`;
        return m;
      };
      const dpr = this.dpr;
      // The body's thickness: slices of the device's own outline stacked
      // behind the screen, so a tilted half shows its rim and the corners
      // stay round. Drawn once (`_drawRims`), then only composited.
      const T = Math.max(4, Math.round(rect.width * THICKNESS));
      const slices = Math.max(4, Math.min(12, Math.round(T / 2)));
      const leaf = (side) => {
        const el = document.createElement('div');
        el.style.cssText = [
          'position:absolute', 'top:0', 'height:100%', `width:${halfW}px`,
          side === 'left' ? 'left:0' : `left:${halfW}px`,
          side === 'left' ? 'transform-origin:100% 50%' : 'transform-origin:0 50%',
          'transform-style:preserve-3d', 'will-change:transform',
        ].join(';');
        const plain = `position:absolute;left:0;top:0;width:${halfW}px;height:${H}px;pointer-events:none;`;
        const box = plain + 'backface-visibility:hidden;-webkit-backface-visibility:hidden;';
        const rims = [];
        for (let i = 1; i <= slices; i++) {
          const s = document.createElement('canvas');
          s.width = Math.max(1, Math.round(halfW * RIM_SCALE));
          s.height = Math.max(1, Math.round(H * RIM_SCALE));
          s.style.cssText = plain + `transform:translateZ(${-(i / slices) * T}px);`;
          el.appendChild(s);
          rims.push(s);
        }
        const c = document.createElement('canvas');
        c.width = Math.round(halfW * dpr); c.height = Math.round(H * dpr);
        c.style.cssText = box;
        el.appendChild(c);
        let back = null;
        if (side === 'left' && this.back) {
          back = document.createElement('canvas');
          back.width = c.width; back.height = c.height;
          back.style.cssText = box + `transform:translateZ(${-T - 0.5}px) rotateY(180deg);`;
          el.appendChild(back);
        }
        // This half's share of the screen, leaf-local: TL, TR, BR, BL.
        const x0 = side === 'left' ? screenBox.left : 0;
        const x1 = side === 'left' ? halfW : screenBox.left + screenBox.width - halfW;
        const y0 = screenBox.top, y1 = screenBox.top + screenBox.height;
        const corners = [marker(x0, y0), marker(x1, y0), marker(x1, y1), marker(x0, y1)];
        corners.forEach((m) => el.appendChild(m));
        return { el, canvas: c, back, corners, rims };
      };
      this.rimsDrawn = false;
      this.leaves = { left: leaf('left'), right: leaf('right') };
      stage.appendChild(this.leaves.left.el);
      stage.appendChild(this.leaves.right.el);
      document.body.appendChild(stage);
      this.stage = stage;
      this.halfW = halfW;
      this.height = H;
      this.seamFraction = (halfW - screenBox.left) / screenBox.width;
      this.host = wrapper.parentElement;
      if (this.host) this.host.style.visibility = 'hidden';
      window.addEventListener('resize', this._onResize);
      this.frozen = false;
      if (this.onMount) this.onMount(stage);
      return true;
    }

    _quad(leaf) {
      return root.Baguette._ScreenQuad.fromCorners(leaf.corners.map((m) => {
        const r = m.getBoundingClientRect();
        return [r.left + r.width / 2, r.top + r.height / 2];
      }));
    }

    /** Client point → screen point through the half it lands on. The
     *  left half's screen faces away once it has turned past 90°. */
    mapClientPoint(clientX, clientY, size) {
      const miss = { x: 0, y: 0, xNorm: 0, yNorm: 0, inside: false };
      if (!this.leaves) return miss;
      const s = this.seamFraction;
      const hit = (xNorm, yNorm) => ({
        x: xNorm * size.width, y: yNorm * size.height, xNorm, yNorm, inside: true,
      });
      const right = this._quad(this.leaves.right).locate(clientX, clientY);
      if (right.inside) return hit(s + right.u * (1 - s), right.v);
      if (this.leafAngles && this.leafAngles.left < 90) {
        const left = this._quad(this.leaves.left).locate(clientX, clientY);
        if (left.inside) return hit(left.u * s, left.v);
      }
      return miss;
    }

    // Each rim slice is the device's outline (the composed scratch's
    // alpha, turned as the page shows it) filled with its shade.
    _drawRims(W, Hu) {
      const halfW = this.halfW, H = this.height;
      for (const side of ['left', 'right']) {
        const rims = this.leaves[side].rims;
        rims.forEach((slice, i) => {
          const t = rims.length > 1 ? i / (rims.length - 1) : 0;
          const c = RIM_FRONT.map((v, k) => Math.round(v + (RIM_BACK[k] - v) * t));
          const ctx = slice.getContext('2d');
          ctx.setTransform(RIM_SCALE, 0, 0, RIM_SCALE, 0, 0);
          ctx.clearRect(0, 0, halfW, H);
          ctx.save();
          ctx.translate(side === 'left' ? halfW : 0, H / 2);
          ctx.rotate(this.rotation * Math.PI / 180);
          ctx.drawImage(this.scratch, -W / 2, -Hu / 2, W, Hu);
          ctx.restore();
          ctx.globalCompositeOperation = 'source-in';
          ctx.fillStyle = `rgb(${c[0]},${c[1]},${c[2]})`;
          ctx.fillRect(0, 0, halfW, H);
          ctx.globalCompositeOperation = 'source-over';
        });
      }
      this.rimsDrawn = true;
    }

    _tick() {
      this.raf = requestAnimationFrame(() => { this.raf = null; if (this.stage && !this.frozen) this._tick(); });
      const wrapper = this.front.wrapper;
      const W = wrapper.offsetWidth, Hu = wrapper.offsetHeight;
      if (W < 2 || Hu < 2) return;
      compose(this.scratch, W, Hu, this.dpr, {
        bezel: this.frontImgs.bezel, frame: this.front.canvas, screen: this.front.screen,
        mask: this.frontImgs.mask, crease: root.Baguette.BookPose.creaseOpacity(this.degrees),
      });
      const halfW = this.halfW, H = this.height;
      if (!this.rimsDrawn && ready(this.frontImgs.bezel)) this._drawRims(W, Hu);
      for (const side of ['left', 'right']) {
        const ctx = this.leaves[side].canvas.getContext('2d');
        ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
        ctx.clearRect(0, 0, halfW, H);
        ctx.save();
        // Each half holds its own half of the turned device, centred on the crease.
        ctx.translate(side === 'left' ? halfW : 0, H / 2);
        ctx.rotate(this.rotation * Math.PI / 180);
        ctx.drawImage(this.scratch, -W / 2, -Hu / 2, W, Hu);
        ctx.restore();
        // A half turned away from the viewer darkens toward the spine.
        const tilt = this.leafAngles ? Math.min(90, Math.abs(this.leafAngles[side])) : 0;
        const shade = tilt / 90 * 0.45;
        if (shade > 0.01) {
          const spine = side === 'left' ? halfW : 0, outer = side === 'left' ? 0 : halfW;
          const g = ctx.createLinearGradient(outer, 0, spine, 0);
          g.addColorStop(0, 'rgba(0,0,0,0)');
          g.addColorStop(1, `rgba(0,0,0,${shade})`);
          ctx.save();
          ctx.globalCompositeOperation = 'source-atop';
          ctx.fillStyle = g;
          ctx.fillRect(0, 0, halfW, H);
          ctx.restore();
        }
      }
      const back = this.leaves.left.back;
      if (!back || !this.back) return;
      const vp = this.back.screen.viewport;
      // The cover fills its half, hinge side against the crease.
      compose(this.backScratch, vp.width, vp.height, this.dpr, {
        bezel: this.backImgs.bezel, frame: this.back.canvas, screen: this.back.screen,
        mask: this.backImgs.mask, crease: 0,
      });
      const ctx = back.getContext('2d');
      ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
      ctx.clearRect(0, 0, halfW, H);
      ctx.drawImage(this.backScratch, 0, 0, halfW, H);
    }
  }

  root.Baguette = root.Baguette || {};
  root.Baguette.BookView = BookView;
})(window);
