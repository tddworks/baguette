// CaptureGallery — owns the screenshot list: fetches one-frame
// snapshots, composites them at the size the user picked (bezel
// optional), and renders the thumbnail strip. Each entry remembers the
// pixels it came out at and which preset produced them, so the strip
// and the download filename can both say so.
//
// Collaborators (all from Resources/Web/capture/, loaded by sim.html
// BEFORE this file):
//   • CaptureSettings — size + fit + background + withFrame, as one value
//   • CaptureSize     — via `settings.plan()`; the canvas geometry
//   • CaptureComposer — the bezel composite and the source→target paint
//
// A page that doesn't load them still captures — natively, unframed —
// rather than throwing on the Screenshot button; see NativeCapture.
//
//   const gallery = new CaptureGallery({ udid, screen: def.screen, frameImg });
//   await gallery.capture({ settings });          // a CaptureSettings
//   await gallery.capture({ withFrame, naturalSize });  // legacy shape
//   gallery.renderInto(galleryEl, countEl);
//   gallery.clear();
//
// The list is mirrored to `window.simCaptures` for legacy code that
// still inspects it. Doesn't know about WebSocket lifetime or sidebar
// buttons — the orchestrator decides when to capture and when to render.
(function (root) {
  'use strict';

  class CaptureGallery {
    /**
     * @param {object} opts
     * @param {string} opts.udid
     * @param {object|null} opts.screen    SDK SimulatorDefinition.screen
     * @param {HTMLImageElement|null} opts.frameImg  decoded bezel image
     */
    constructor({ udid, screen, frameImg }) {
      this.udid = udid;
      this.screen = screen;
      this.frameImg = frameImg;
      this.captures = [];
      this._mirror();
    }

    /**
     * Fetch a screenshot, compose it at the settings' size, push it onto
     * the list. Returns the entry that was pushed.
     *
     * @param {object} [options]
     * @param {object} [options.settings]  a CaptureSettings
     * @param {boolean} [options.withFrame]        legacy call shape
     * @param {{w:number,h:number}} [options.naturalSize] legacy call shape
     */
    async capture(options = {}) {
      const settings = this._settingsFrom(options);
      const withBezel = settings.withFrame && this._hasBezel();

      const shot = await this._fetchScreenshot(settings, withBezel);
      const natural = this._composite(shot.image, withBezel, options.naturalSize);
      const plan = settings.plan(natural.width, natural.height);
      const dataUrl = this._paint(plan, settings, shot, withBezel, natural.scale);

      return this._push({
        dataUrl,
        w: plan.width,
        h: plan.height,
        withFrame: withBezel,
        sizeId: settings.size.id,
        sizeLabel: settings.size.label,
        slug: settings.slug(plan.width, plan.height),
      });
    }

    /** Drop every capture. */
    clear() {
      this.captures = [];
      this._mirror();
    }

    /** Paint the strip into `galleryEl`, the count into `countEl`. */
    renderInto(galleryEl, countEl) {
      if (!galleryEl) return;
      const items = this.captures;
      if (countEl) countEl.textContent = items.length ? `(${items.length})` : '';

      galleryEl.innerHTML = '';
      if (!items.length) {
        galleryEl.appendChild(this._emptyNote());
        return;
      }
      items.forEach((entry, i) => galleryEl.appendChild(this._thumb(entry, i)));
    }

    // ── request ────────────────────────────────────────────────

    /**
     * The screenshot as `{ image, dataUrl }` — decoded and ready to
     * `drawImage`, plus the bytes the route actually sent, which an
     * untouched capture can keep verbatim.
     *
     * The size vocabulary rides along as `?size=&fit=&background=` — the
     * same names `baguette screenshot` takes — so a server that resizes
     * can hand back a finished image. A server that ignores them changes
     * nothing: the client re-plans the same size below, and re-planning a
     * size onto an image already at that size is the identity transform.
     *
     * The one case that must NOT be resized server-side is a bezel
     * composite: the screen has to arrive unpadded to paste into the
     * cutout, and the resize then happens around the whole composite.
     */
    async _fetchScreenshot(settings, withBezel) {
      const query = withBezel ? {} : settings.toQuery();
      const params = new URLSearchParams({ t: String(Date.now()), ...query });
      // The page's own device tree: a phone's page asks `/devices/…`.
      const target = root.BaguetteTarget;
      const base = target
        ? target.path(this.udid, '/screenshot.jpg')
        : `/devices/${encodeURIComponent(this.udid)}/screenshot.jpg`;
      const url = `${base}?${params.toString()}`;
      const res = await root.fetch(url);
      // The route answers a bad UDID or a failed grab with a JSON body,
      // which would otherwise decode-fail as "not an image" and throw the
      // server's own message away.
      if (!res.ok) {
        const detail = res.text ? await res.text().catch(() => '') : '';
        throw new Error(`screenshot failed (${res.status}) ${detail}`.trim());
      }
      const dataUrl = await blobToDataUrl(root, await res.blob());
      return { image: await decodeImage(root, dataUrl), dataUrl };
    }

    /** A bezel composite needs both the artwork and the composer. */
    _hasBezel() {
      const img = this.frameImg;
      return !!(img && img.naturalWidth > 0
        && this.screen && this.screen.viewport && this.screen.rect
        && composerOrNull());
    }

    // ── composition ────────────────────────────────────────────

    /**
     * The composite at capture scale, before the picked size is applied.
     * `CaptureComposer.composite` grows a point-authored bezel until its
     * cutout is 1:1 with the screenshot, so an App Store size resamples
     * from the full framebuffer rather than from a ~3x-shrunk copy of it.
     */
    _composite(image, withBezel, legacyNaturalSize) {
      const composer = composerOrNull();
      const size = composer
        ? composer.composite(
          withBezel ? this.frameImg : null,
          withBezel ? this.screen : null,
          image
        )
        : { width: image.width || 0, height: image.height || 0, scale: 1 };
      if (size.width > 0 && size.height > 0) return size;
      // Defensive: an image that decoded without dimensions would give a
      // 0 × 0 canvas — fall back to the size the stream last painted at.
      return {
        width: legacyNaturalSize ? legacyNaturalSize.w : 0,
        height: legacyNaturalSize ? legacyNaturalSize.h : 0,
        scale: 1,
      };
    }

    /**
     * The finished capture as a data URL. A capture that neither wears a
     * bezel nor changes shape IS the bytes the route sent, so it keeps
     * them — re-encoding a 1290 × 2796 JPEG as lossless PNG would cost
     * megabytes per thumbnail for an identical picture.
     */
    _paint(plan, settings, shot, withBezel, scale) {
      if (!withBezel && isIdentity(plan)
        && settings.effectiveBackground === 'transparent') {
        return shot.dataUrl;
      }
      const composer = composerOrNull();
      if (!composer) return shot.dataUrl;
      const canvas = root.document.createElement('canvas');
      canvas.width = plan.width;
      canvas.height = plan.height;
      const ctx = canvas.getContext('2d');
      composer.compose(ctx, plan, settings.effectiveBackground, (c) => {
        // `compose` set the transform for a source the size of the grown
        // composite; `paintComposite` paints at the bezel's own size, so
        // the supersample factor goes on here.
        if (scale && scale !== 1) c.scale(scale, scale);
        composer.paintComposite(c, {
          frameImg: withBezel ? this.frameImg : null,
          screen: withBezel ? this.screen : null,
          sourceCanvas: shot.image,
        });
      });
      return canvas.toDataURL('image/png');
    }

    // ── list ───────────────────────────────────────────────────

    _push(entry) {
      const stored = { name: `Screen ${this.captures.length + 1}`, ...entry };
      this.captures.push(stored);
      this._mirror();
      return stored;
    }

    /**
     * Legacy code reads `window.simCaptures` directly. One gallery owns
     * the mirror for as long as it lives; a new gallery (a new stream)
     * starts a fresh strip rather than inheriting the last device's.
     */
    _mirror() {
      root.simCaptures = this.captures;
    }

    /**
     * Legacy `{ withFrame, naturalSize }` call shape → a native capture.
     * `withFrame` defaults to OFF here, the way it always did — the
     * CaptureSettings default (on) is for the picker, not for a caller
     * that left the flag out.
     */
    _settingsFrom(options) {
      if (options.settings) return options.settings;
      const CaptureSettings = root.Baguette && root.Baguette._CaptureSettings;
      return CaptureSettings
        ? new CaptureSettings({ withFrame: !!options.withFrame })
        : new NativeCapture(!!options.withFrame);
    }

    // ── strip DOM ──────────────────────────────────────────────

    _emptyNote() {
      const note = root.document.createElement('div');
      note.style.cssText =
        'color:var(--text-muted);font-size:11px;padding:8px';
      note.textContent = 'No captures yet';
      return note;
    }

    /**
     * One thumbnail: the image, a dimensions chip, and the `F` badge when
     * the bezel was composited in. Clicking downloads it — a real
     * listener, not an `onclick` attribute with a megabyte-long data URL
     * interpolated into it.
     */
    _thumb(entry, index) {
      const doc = root.document;
      const wrap = doc.createElement('div');
      wrap.style.cssText = 'position:relative;width:56px;cursor:pointer';
      wrap.title = this._thumbTitle(entry);

      const img = doc.createElement('img');
      img.src = entry.dataUrl;
      img.alt = '';
      img.style.cssText =
        'width:56px;border-radius:4px;border:1px solid var(--border);display:block';
      img.addEventListener('click', () => this._download(entry, index));
      wrap.appendChild(img);

      const dims = doc.createElement('div');
      dims.style.cssText = 'position:absolute;left:2px;bottom:2px;'
        + 'background:rgba(0,0,0,.6);color:white;font-size:7px;'
        + 'padding:1px 3px;border-radius:2px;line-height:1';
      dims.textContent = `${entry.w}×${entry.h}`;
      wrap.appendChild(dims);

      if (entry.withFrame) {
        const badge = doc.createElement('div');
        badge.style.cssText = 'position:absolute;top:2px;right:2px;'
          + 'background:var(--accent,#2563EB);color:white;font-size:7px;'
          + 'padding:1px 3px;border-radius:2px;line-height:1';
        badge.textContent = 'F';
        wrap.appendChild(badge);
      }
      return wrap;
    }

    _thumbTitle(entry) {
      const parts = [`${entry.name} — ${entry.w} × ${entry.h}`];
      if (entry.sizeId && entry.sizeId !== 'native') parts.push(entry.sizeLabel);
      if (entry.withFrame) parts.push('with frame');
      return parts.join(' · ');
    }

    /** `capture-3-appstore-6.9-1290x2796.png` — the slug arrives from
     *  CaptureSettings already filename-safe, so screenshots and
     *  recordings can't drift apart on how they name a `16:9` file. */
    _download(entry, index) {
      const a = root.document.createElement('a');
      a.href = entry.dataUrl;
      a.download = `capture-${index + 1}-${entry.slug}.png`;
      a.click();
    }
  }

  // ── helpers ──────────────────────────────────────────────────

  /**
   * The read surface of CaptureSettings for a plain native capture —
   * what a legacy caller gets when the capture vocabulary
   * (Resources/Web/capture/*.js) isn't on the page. Native means every
   * question has a trivial answer, so this stays a handful of lines
   * rather than a second implementation of the size maths.
   */
  class NativeCapture {
    constructor(withFrame) {
      this.withFrame = withFrame;
      this.size = { id: 'native', label: 'Native', spec: 'native', isNative: true };
      this.effectiveBackground = 'transparent';
    }

    toQuery() { return {}; }

    plan(width, height) {
      return {
        width, height, drawX: 0, drawY: 0, drawW: width, drawH: height,
        sourceWidth: width, sourceHeight: height,
      };
    }

    slug(width, height) {
      return `${Math.round(width)}x${Math.round(height)}`;
    }
  }

  const composerOrNull = () =>
    (root.Baguette && root.Baguette._CaptureComposer) || null;

  /** True when the plan draws the source unscaled, unmoved, unpadded. */
  function isIdentity(plan) {
    return plan.drawX === 0 && plan.drawY === 0
      && plan.drawW === plan.width && plan.drawH === plan.height
      && plan.width === plan.sourceWidth && plan.height === plan.sourceHeight;
  }

  function blobToDataUrl(win, blob) {
    return new Promise((resolve) => {
      const fr = new win.FileReader();
      fr.onloadend = () => resolve(fr.result);
      fr.readAsDataURL(blob);
    });
  }

  /** A decoded <img>, which `drawImage` takes exactly like a canvas. */
  function decodeImage(win, dataUrl) {
    return new Promise((resolve, reject) => {
      const img = new win.Image();
      img.onload = () => resolve(img);
      img.onerror = () => reject(new Error('screenshot decode failed'));
      img.src = dataUrl;
    });
  }

  root.CaptureGallery = CaptureGallery;
})(window);
