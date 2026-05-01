// CaptureGallery — owns the screenshot list, fetches one-frame
// snapshots, optionally composites with the bezel, and renders the
// thumbnail strip. The captures array is mirrored to
// `window.simCaptures` for any legacy code that still inspects it.
//
//   const gallery = new CaptureGallery({ udid, layout, frameImg });
//   await gallery.capture({ withFrame: true, naturalSize: { w, h } });
//   gallery.renderInto(galleryEl, countEl);
//   gallery.clear();
//
// Doesn't know about WebSocket lifetime or sidebar buttons. The
// orchestrator decides when to call `capture` and when to render.
(function () {
  'use strict';

  function CaptureGallery({ udid, layout, frameImg }) {
    this.udid = udid;
    this.layout = layout;
    this.frameImg = frameImg;
    window.simCaptures = window.simCaptures || [];
  }

  /** Fetch a screenshot, optionally composite it onto the bezel,
   *  push onto the captures array. Returns the entry's metadata. */
  CaptureGallery.prototype.capture = async function ({ withFrame, naturalSize }) {
    const url = `/simulators/${encodeURIComponent(this.udid)}/screenshot.jpg?t=${Date.now()}`;
    const blob = await (await fetch(url)).blob();
    const screenshotUrl = await blobToDataUrl(blob);

    const fimg = this.frameImg;
    const wantFrame = withFrame && fimg && fimg.naturalWidth > 0;

    if (wantFrame) {
      const dataUrl = await composite(screenshotUrl, fimg, this.layout);
      const fw = fimg.naturalWidth, fh = fimg.naturalHeight;
      this._push({ dataUrl, w: fw, h: fh, withFrame: true });
      return { withFrame: true, w: fw, h: fh };
    }

    this._push({
      dataUrl: screenshotUrl,
      w: naturalSize ? naturalSize.w : 0,
      h: naturalSize ? naturalSize.h : 0,
      withFrame: false,
    });
    return { withFrame: false, w: naturalSize?.w ?? 0, h: naturalSize?.h ?? 0 };
  };

  CaptureGallery.prototype._push = function (entry) {
    window.simCaptures.push({
      name: `Screen ${window.simCaptures.length + 1}`,
      ...entry,
    });
  };

  CaptureGallery.prototype.clear = function () {
    window.simCaptures = [];
  };

  CaptureGallery.prototype.renderInto = function (galleryEl, countEl) {
    if (!galleryEl) return;
    const items = window.simCaptures;
    if (countEl) countEl.textContent = items.length ? `(${items.length})` : '';

    if (!items.length) {
      galleryEl.innerHTML =
        '<div style="color:var(--text-muted);font-size:11px;padding:8px">No captures yet</div>';
      return;
    }
    galleryEl.innerHTML = items.map((c, i) => `
      <div style="position:relative;width:56px;cursor:pointer">
        <img src="${c.dataUrl}" alt=""
             style="width:56px;border-radius:4px;border:1px solid var(--border);display:block"
             onclick="(function(){const a=document.createElement('a');a.href='${c.dataUrl}';a.download='capture_${i}.png';a.click()})()">
        ${c.withFrame
          ? '<div style="position:absolute;top:2px;right:2px;background:var(--accent,#2563EB);color:white;font-size:7px;padding:1px 3px;border-radius:2px;line-height:1">F</div>'
          : ''}
      </div>`).join('');
  };

  // ── helpers ──────────────────────────────────────────────────

  function blobToDataUrl(blob) {
    return new Promise((resolve) => {
      const fr = new FileReader();
      fr.onloadend = () => resolve(fr.result);
      fr.readAsDataURL(blob);
    });
  }

  /** Draw the screenshot inside the bezel cutout (clipped to the
   *  inner corner radius), then overlay the bezel image on top. */
  function composite(screenshotDataUrl, frameImg, layout) {
    return new Promise((resolve) => {
      const fw = frameImg.naturalWidth, fh = frameImg.naturalHeight;
      const s = (layout && layout.screen) || null;
      const ix = s ? s.x      : 0;
      const iy = s ? s.y      : 0;
      const sw = s ? s.width  : fw;
      const sh = s ? s.height : fh;
      const radius = (layout && typeof layout.innerCornerRadius === 'number')
        ? layout.innerCornerRadius : 0;

      const canvas = document.createElement('canvas');
      canvas.width = fw; canvas.height = fh;
      const ctx = canvas.getContext('2d');

      const ssImg = new Image();
      ssImg.onload = () => {
        ctx.save();
        ctx.beginPath();
        ctx.moveTo(ix + radius, iy);
        ctx.lineTo(ix + sw - radius, iy);
        ctx.quadraticCurveTo(ix + sw, iy, ix + sw, iy + radius);
        ctx.lineTo(ix + sw, iy + sh - radius);
        ctx.quadraticCurveTo(ix + sw, iy + sh, ix + sw - radius, iy + sh);
        ctx.lineTo(ix + radius, iy + sh);
        ctx.quadraticCurveTo(ix, iy + sh, ix, iy + sh - radius);
        ctx.lineTo(ix, iy + radius);
        ctx.quadraticCurveTo(ix, iy, ix + radius, iy);
        ctx.closePath();
        ctx.clip();
        ctx.drawImage(ssImg, ix, iy, sw, sh);
        ctx.restore();
        ctx.drawImage(frameImg, 0, 0, fw, fh);
        resolve(canvas.toDataURL('image/png'));
      };
      ssImg.src = screenshotDataUrl;
    });
  }

  window.CaptureGallery = CaptureGallery;
})();
