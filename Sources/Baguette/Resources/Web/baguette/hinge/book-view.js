// BookView — the flat view's unfolded device split at the crease into two
// halves turned in CSS 3D (`BookPose`), the live cover on the left half's
// back. Integration-only: DOM and canvas.
(function (root) {
  'use strict';

  const RIM_SCALE = 0.5;   // an edge, never read closely
  const RIM_FRONT = [92, 92, 97];
  const RIM_BACK = [28, 28, 31];

  function loadImage(src) {
    if (!src) return null;
    const img = new Image();
    img.src = src;
    return img;
  }
  const ready = (img) => !!(img && img.complete && img.naturalWidth);

  // Bezel, masked screen and crease into `scratch`, in the device's unrotated layout.
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
     * @param {object} front  `{ wrapper, canvas, screenArea, screen }` of the unfolded device
     * @param {object} back   `{ canvas, screen }` — the live cover feed
     * @param {number} rotation  the page's CSS rotation of `wrapper`, degrees
     * @param {object} [opts]  `onMount(stage)` to bind input; `layer` to add the stage to
     */
    constructor(front, back, rotation, { onMount, layer } = {}) {
      this.front = front;
      this.back = back;
      this.onMount = onMount || null;
      this.layer = layer || document.body;
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
      this._onResize = () => this.relayout();
    }

    /** Re-mounts over the device where it now stands. */
    relayout() {
      if (!this.stage) return;
      this._unmount();
      this.show(this.degrees);
    }

    /** Only a vertical crease folds as a book on the page. */
    static canFold(rotation) {
      return (((rotation % 360) + 360) % 360) % 180 === 90;
    }

    show(degrees) {
      this.degrees = degrees;
      if (this.disposed) return;
      if (!this.stage && !this._mount()) {
        // Not laid out yet; retry next frame rather than on the next sample.
        if (!this.retry) {
          this.retry = requestAnimationFrame(() => { this.retry = 0; this.show(this.degrees); });
        }
        return;
      }
      const a = root.Baguette.BookPose.leaves(degrees);
      this.leafAngles = a;
      this.leaves.left.el.style.transform = `rotateY(${a.left}deg)`;
      this.leaves.right.el.style.transform = `rotateY(${a.right}deg)`;
      this.leaves.left.el.style.zIndex = a.left > 90 ? '2' : '1';
      const BookPose = root.Baguette.BookPose;
      this.stage.style.transform = `translateX(${BookPose.shift(degrees, this.halfW)}px)`
        + ` scale(${BookPose.stageScale(degrees)})`;
      if (!this.raf) this._tick();
    }

    freeze() {
      if (this.raf) { cancelAnimationFrame(this.raf); this.raf = null; }
      this.frozen = true;
    }

    fadeOut(ms) {
      // Not mounted yet: dispose, or the pending retry mounts it later.
      if (!this.stage) { this.dispose(); return; }
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
        'z-index:30', `perspective:${root.Baguette.BookPose.PERSPECTIVE * rect.width}px`,
        'perspective-origin:50% 50%',
        'cursor:crosshair', 'touch-action:none', 'user-select:none', '-webkit-user-select:none',
      ].join(';');
      const marker = (x, y) => {
        const m = document.createElement('div');
        m.style.cssText = `position:absolute;left:${x}px;top:${y}px;width:1px;height:1px;pointer-events:none;`;
        return m;
      };
      const dpr = this.dpr;
      // Thickness: slices of the device's outline stacked behind the screen, drawn once.
      const T = Math.max(4, Math.round(rect.width * root.Baguette.BookPose.THICKNESS));
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
          // At its own shape, centred on the half: where the flat cover stands.
          const cvp = this.back.screen.viewport;
          const o = root.Baguette.BookPose.coverOverhang(halfW, H, cvp.width / cvp.height);
          this.coverWidth = halfW + 2 * o;
          back = document.createElement('canvas');
          back.width = Math.round(this.coverWidth * dpr); back.height = c.height;
          back.style.cssText = plain + `left:${-o}px;width:${this.coverWidth}px;`
            + 'backface-visibility:hidden;-webkit-backface-visibility:hidden;'
            + `transform:translateZ(${-T - 0.5}px) rotateY(180deg);`;
          el.appendChild(back);
        }
        // Screen corners (TL, TR, BR, BL), projected by the browser for mapClientPoint.
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
      this.layer.appendChild(stage);
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

    /** Client point → screen point; the left half faces away past 90°. */
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
        ctx.translate(side === 'left' ? halfW : 0, H / 2);
        ctx.rotate(this.rotation * Math.PI / 180);
        ctx.drawImage(this.scratch, -W / 2, -Hu / 2, W, Hu);
        ctx.restore();
        // Darken toward the spine as the half turns away.
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
      compose(this.backScratch, vp.width, vp.height, this.dpr, {
        bezel: this.backImgs.bezel, frame: this.back.canvas, screen: this.back.screen,
        mask: this.backImgs.mask, crease: 0,
      });
      const ctx = back.getContext('2d');
      ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
      ctx.clearRect(0, 0, this.coverWidth, H);
      ctx.drawImage(this.backScratch, 0, 0, this.coverWidth, H);
    }
  }

  root.Baguette = root.Baguette || {};
  root.Baguette.BookView = BookView;
})(window);
