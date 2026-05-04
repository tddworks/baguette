// BezelButtons — DOM overlay of clickable hardware buttons (action,
// volume-up / volume-down, power, home, …) over a bare bezel image.
//
// Used by the "actionable bezel" mode (toggle in focus mode's top
// toolbar). When active, `device-frame.js` fetches
// `bezel.png?buttons=false` and asks this module to lay each button
// from `chrome.json` over the bare bezel as its own animated <img>.
//
//   const bb = new BezelButtons({ udid, layout, onPress });
//   bb.mount(wrapperElement);
//
// Layout shape (from chrome.json):
//   composite       — { width, height }   merged-bezel size (with margins)
//   buttonMargins   — { top,left,bottom,right } overshoot the merge added
//   buttons[]       — each entry has name / imageName / anchor / align /
//                     normalOffset / rolloverOffset / onTop / imageUrl
//
// The bare bezel's logical dimensions are `composite − margins`. Every
// position computed below is relative to the BARE bezel image element,
// expressed in percentages so the overlay scales with the bezel.
//
// Hover behaviour mirrors the macOS Tahoe Simulator: each chrome button
// ships TWO offsets in DeviceKit's data — `normalOffset` (at-rest) and
// `rolloverOffset` (popped out a few px on hover). We position at
// normal, animate to rollover on hover, and depress slightly past
// normal on mousedown. Click fires `onPress(name)`.
//
// Buttons whose names map to wire events (`power` → `lock`, `home` →
// `home`) are active; the rest are visible but show a tooltip
// explaining they're not on the host-HID path on iOS 26.4.
(function () {
  'use strict';

  // Map chrome.json `name` (hyphenated, as DeviceKit ships them) to
  // the wire `button` value the GestureRegistry accepts. iOS 26.4
  // only routes `home` and `lock` — every other button is visible
  // but inert with an explanatory tooltip.
  const WIRE_BUTTON = {
    power:        'lock',  // iPhone power / sleep-wake (right side)
    'side-button': 'lock',  // future-proof if DeviceKit renames
    home:         'home',  // older iPhones
  };

  function BezelButtons({ udid, layout, onPress }) {
    this.udid = udid;
    this.layout = layout || {};
    this.onPress = onPress || (() => {});
    this._els = [];
  }

  /**
   * Append button elements as siblings of the bezel <img> inside
   * `wrapper`. The wrapper is `position: relative` (set by
   * device-frame.js). Positions are percentages of the BARE bezel
   * dimensions so the overlay tracks the bezel as it scales with
   * viewport.
   */
  BezelButtons.prototype.mount = function (wrapper) {
    this.unmount();
    const buttons = (this.layout.buttons) || [];
    if (!buttons.length) return;

    const m = this.layout.buttonMargins || { top: 0, left: 0, bottom: 0, right: 0 };
    const merged = this.layout.composite || { width: 0, height: 0 };
    // Bare composite dims = merged − margins. The bezel image we
    // overlay is bare, so positions are computed in this space.
    const bareW = Math.max(1, (merged.width  || 0) - (m.left || 0) - (m.right || 0));
    const bareH = Math.max(1, (merged.height || 0) - (m.top  || 0) - (m.bottom || 0));

    for (const b of buttons) {
      const el = this._buildButton(b, bareW, bareH);
      if (!el) continue;
      wrapper.appendChild(el);
      this._els.push(el);
    }
  };

  BezelButtons.prototype.unmount = function () {
    for (const el of this._els) {
      try { el.remove(); } catch (_) { /* ignore */ }
    }
    this._els = [];
  };

  BezelButtons.prototype._buildButton = function (b, bareW, bareH) {
    if (!b || !b.imageUrl) return null;

    const wire = WIRE_BUTTON[b.name] || null;
    const wrap = document.createElement('button');
    wrap.type = 'button';
    wrap.dataset.btn = b.name;
    wrap.title = wire
      ? `${humanizeName(b.name)} → ${wire}`
      : `${humanizeName(b.name)} — not wired on iOS 26.4`;
    wrap.setAttribute('aria-label', wrap.title);
    wrap.style.cssText = [
      'position:absolute',
      'padding:0',
      'border:0',
      'background:transparent',
      'cursor:pointer',
      // Render BEHIND the bezel <img> (which is z=1). DeviceKit's
      // chrome data marks iPhone power/volume/action with
      // `onTop:false` — i.e. the cap should sit behind the device
      // body so only the part overshooting the bezel edge stays
      // visible. That's how a real iPhone looks: the cap pokes out
      // through a slot in the side rail. z=0 + the opaque bezel
      // composite gives us that exact occlusion for free, with no
      // CSS clip-path math.
      'z-index:0',
      'transition:transform 160ms cubic-bezier(0.2, 0.7, 0.2, 1.0)',
      '-webkit-user-select:none',
      'user-select:none',
    ].join(';');

    const img = new Image();
    img.src = b.imageUrl;
    img.draggable = false;
    img.alt = '';
    img.style.cssText = 'display:block;pointer-events:none;width:100%;height:100%';
    wrap.appendChild(img);

    img.addEventListener('load', () => this._size(wrap, img, b, bareW, bareH));
    if (img.complete && img.naturalWidth) this._size(wrap, img, b, bareW, bareH);

    // Three-state animation driven by DeviceKit's two offsets:
    //   AT REST  → rollover position (cap visibly pokes out — same
    //              spot the static composite bakes in).
    //   HOVER    → translate further outward by the same delta,
    //              advertising "this is interactive".
    //   PRESSED  → translate to NORMAL position (cap recedes into
    //              the bezel, like a real depressed button).
    //
    // Important math note: CSS `translate(N%)` resolves against the
    // ELEMENT'S OWN border box, not its parent. The button is tiny
    // (16 px wide on iPhone vs ~436 wide bezel), so the rollover
    // delta (5 chrome px) is ~1% of the bezel BUT ~31% of the
    // button. We compute the delta as a percent of `iw`/`ih` so the
    // translate actually moves the cap by the chrome-pixel amount
    // DeviceKit specified — not 1/30th of that.
    img.addEventListener('load', () => this._wireAnim(wrap, img, b));
    if (img.complete && img.naturalWidth) this._wireAnim(wrap, img, b);
    wrap.addEventListener('click', (ev) => {
      ev.preventDefault();
      ev.stopPropagation();
      if (wire) this.onPress(wire);
      // Inert buttons silently no-op — title attribute already
      // explains why nothing happened.
    });

    return wrap;
  };

  /**
   * Bind hover / press translates AFTER the image has loaded so we
   * know its natural dimensions. We translate by `(delta / imgSize)
   * × 100%` so the CSS `translate(...)` (which resolves against the
   * element's OWN size) actually moves the cap by the chrome-pixel
   * delta DeviceKit specifies. Without dividing by imgSize, the
   * translate would be ~1/30th the intended distance and the
   * animation would be visually invisible.
   */
  BezelButtons.prototype._wireAnim = function (wrap, img, b) {
    const iw = img.naturalWidth  || 1;
    const ih = img.naturalHeight || 1;
    const normal   = b.normalOffset   || b.offset || { x: 0, y: 0 };
    const rollover = b.rolloverOffset || b.offset || normal;
    // Direction & magnitude of the at-rest → hover slide, expressed
    // as a percent of the button image's own width/height. For
    // iPhone left buttons rollover.x = 3, normal.x = 8 → -5 chrome
    // px / 16 px image = −31.25%. The button visibly pops outward.
    const outDx = ((rollover.x - normal.x) / iw) * 100;
    const outDy = ((rollover.y - normal.y) / ih) * 100;
    wrap.style.setProperty('--out-dx', `${outDx}%`);
    wrap.style.setProperty('--out-dy', `${outDy}%`);

    wrap.addEventListener('mouseenter', () => {
      wrap.style.transform = 'translate(var(--out-dx), var(--out-dy))';
    });
    wrap.addEventListener('mouseleave', () => {
      wrap.style.transform = '';
    });
    wrap.addEventListener('mousedown', () => {
      // Press back to NORMAL — opposite sign of the rollover delta.
      wrap.style.transform =
        'translate(calc(var(--out-dx) * -1), calc(var(--out-dy) * -1))';
    });
    wrap.addEventListener('mouseup', () => {
      wrap.style.transform = 'translate(var(--out-dx), var(--out-dy))';
    });
  };

  /**
   * Position `wrap` once the button image has natural dimensions.
   * Width/height are expressed as percentages of the BARE bezel so
   * the overlay scales with the bezel as the viewport resizes.
   * Positioning sits the button image's CENTRE at the chrome-pixel
   * point that DeviceKit names — `normalOffset` from the anchor
   * edge — so the cap straddles the bezel side rail the way the
   * real iPhone hardware does.
   */
  BezelButtons.prototype._size = function (wrap, img, b, bareW, bareH) {
    const iw = img.naturalWidth  || 1;
    const ih = img.naturalHeight || 1;

    const wPct = (iw / bareW) * 100;
    const hPct = (ih / bareH) * 100;
    wrap.style.width  = `${wPct}%`;
    wrap.style.height = `${hPct}%`;

    // Anchor maps to a side of the bare bezel; align controls how
    // the button sits along the perpendicular axis. We position at
    // the ROLLOVER offset (matching the static composite's bake-in
    // position) so the cap actually pokes out — at NORMAL the
    // entire image would sit inside the bezel's side rail (button
    // images are 16 px wide; at offset.x = 8 the cap is exactly
    // flush with the edge). The mousedown handler animates back
    // to normal to give the depress feel.
    //
    // The Swift rasterizer (`buttonTopLeft` in LiveChromes) places
    // the button image's CENTRE at the chosen offset — we mirror
    // that here so positions line up with the static composite.
    const halfWPct = (iw / 2 / bareW) * 100;
    const halfHPct = (ih / 2 / bareH) * 100;
    const off = b.rolloverOffset || b.offset || b.normalOffset || { x: 0, y: 0 };

    switch (b.anchor) {
      case 'left': {
        // Centre at (off.x, off.y) inside the bare bezel's left edge.
        const cxPct = (off.x / bareW) * 100;
        const cyPct = (off.y / bareH) * 100;
        wrap.style.left = `${cxPct - halfWPct}%`;
        wrap.style.top  = `${cyPct - halfHPct}%`;
        break;
      }
      case 'right': {
        // Centre at (bareW + off.x, off.y) — chrome.json's right
        // anchor uses negative offset.x to push the cap inward.
        const cxPct = ((bareW + off.x) / bareW) * 100;
        const cyPct = (off.y / bareH) * 100;
        wrap.style.left = `${cxPct - halfWPct}%`;
        wrap.style.top  = `${cyPct - halfHPct}%`;
        break;
      }
      case 'top': {
        const baseX = b.align === 'trailing' ? bareW : 0;
        const cxPct = ((baseX + off.x) / bareW) * 100;
        const cyPct = (off.y / bareH) * 100;
        wrap.style.left = `${cxPct - halfWPct}%`;
        wrap.style.top  = `${cyPct - halfHPct}%`;
        break;
      }
      case 'bottom': {
        const baseX = b.align === 'trailing' ? bareW : 0;
        const cxPct = ((baseX + off.x) / bareW) * 100;
        const cyPct = ((bareH + off.y) / bareH) * 100;
        wrap.style.left = `${cxPct - halfWPct}%`;
        wrap.style.top  = `${cyPct - halfHPct}%`;
        break;
      }
      default: {
        const cxPct = (off.x / bareW) * 100;
        const cyPct = (off.y / bareH) * 100;
        wrap.style.left = `${cxPct - halfWPct}%`;
        wrap.style.top  = `${cyPct - halfHPct}%`;
      }
    }
  };

  // "volume-up" → "Volume Up". Used in tooltip + aria-label.
  function humanizeName(name) {
    if (!name) return 'Button';
    return name
      .split(/[-_]/)
      .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
      .join(' ')
      .trim();
  }

  window.BezelButtons = BezelButtons;
})();
