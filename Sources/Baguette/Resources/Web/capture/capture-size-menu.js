// CaptureSizeMenu — the output-size picker every capture surface mounts:
// a chip showing the current selection, and a popover with the preset
// list, the fit toggle, the letterbox background, a custom WxH field, and
// the bezel switch. All it owns is DOM; the selection itself is a
// CaptureSettings value (capture-settings.js) that the menu hands back on
// every change and persists under `storageKey`.
//
//   const menu = new CaptureSizeMenu({
//     storageKey: 'asc.capture.native',
//     onChange: (settings) => { currentSettings = settings; },
//   });
//   menu.mount(document.getElementById('nativeCaptureSize'));
//   menu.settings          // → CaptureSettings, restored from storage
//   menu.detach();
//
// DOM rendering is integration-only in this codebase (same bar as
// sim-native.js / farm-focus.js); the parts worth asserting on — the
// preset catalogue, the placement maths, persistence — live in
// CaptureSize / CaptureSettings and are unit-tested there.
(function () {
  'use strict';

  const STYLE_ID = 'baguetteCaptureSizeMenuStyle';
  const CSS = `
.cap-size { position: relative; display: inline-flex; }
.cap-size-chip {
  display: inline-flex; align-items: center; gap: 5px;
  height: 26px; padding: 0 9px; border-radius: 7px; cursor: pointer;
  font: 600 11px/1 ui-sans-serif, -apple-system, system-ui, sans-serif;
  letter-spacing: 0.01em; white-space: nowrap;
  color: var(--nv-text, var(--text, #1f2937));
  background: var(--nv-btn, var(--surface, #f3f4f6));
  border: 1px solid var(--nv-border, var(--border, #e5e7eb));
}
.cap-size-chip:hover { background: var(--nv-btn-hover, #e5e7eb); }
.cap-size-chip[aria-expanded="true"] {
  border-color: var(--accent, #2563eb); color: var(--accent, #2563eb);
}
.cap-size-chip svg { width: 13px; height: 13px; flex: none; }
.cap-size-pop {
  position: absolute; z-index: 60; top: calc(100% + 6px); right: 0;
  width: 236px; padding: 10px; border-radius: 10px;
  background: var(--nv-panel, var(--surface, #fff));
  border: 1px solid var(--nv-border, var(--border, #e5e7eb));
  box-shadow: 0 12px 32px rgba(15, 23, 42, 0.18);
  font: 500 11px/1.4 ui-sans-serif, -apple-system, system-ui, sans-serif;
  color: var(--nv-text, var(--text, #1f2937));
}
.cap-size-pop[hidden] { display: none; }
.cap-size-head {
  font-size: 9px; font-weight: 700; letter-spacing: 0.07em;
  text-transform: uppercase; color: var(--text-muted, #6b7280);
  margin: 0 0 5px; padding: 0 2px;
}
.cap-size-head:not(:first-child) { margin-top: 10px; }
.cap-size-list { display: flex; flex-direction: column; gap: 2px; }
.cap-size-list button {
  display: flex; align-items: baseline; gap: 6px; width: 100%;
  padding: 5px 7px; border: 0; border-radius: 6px; cursor: pointer;
  background: transparent; color: inherit; font: inherit; text-align: left;
}
.cap-size-list button:hover { background: var(--nv-btn-hover, #f1f5f9); }
.cap-size-list button[aria-checked="true"] {
  background: var(--accent, #2563eb); color: var(--cap-on-accent, #fff);
}
.cap-size-list .dim {
  margin-left: auto; font-size: 10px; font-variant-numeric: tabular-nums;
  color: var(--text-muted, #6b7280);
}
.cap-size-list button[aria-checked="true"] .dim {
  color: var(--cap-on-accent-dim, rgba(255,255,255,0.8));
}
.cap-size-row { display: flex; align-items: center; gap: 6px; }
.cap-size-seg { display: flex; flex: 1; gap: 2px; padding: 2px; border-radius: 7px;
  background: var(--nv-btn, #f3f4f6); }
.cap-size-seg button {
  flex: 1; padding: 4px 0; border: 0; border-radius: 5px; cursor: pointer;
  background: transparent; color: inherit; font: 600 10px/1 inherit;
}
.cap-size-seg button[aria-checked="true"] {
  background: var(--nv-panel, #fff); box-shadow: 0 1px 2px rgba(0,0,0,0.12);
}
.cap-size-row input[type="color"] {
  width: 28px; height: 24px; padding: 0; cursor: pointer;
  border: 1px solid var(--nv-border, #e5e7eb); border-radius: 6px; background: none;
}
.cap-size-row input[type="text"] {
  flex: 1; min-width: 0; height: 24px; padding: 0 7px;
  border: 1px solid var(--nv-border, #e5e7eb); border-radius: 6px;
  background: var(--nv-panel, #fff); color: inherit; font: inherit;
}
.cap-size-row label { display: flex; align-items: center; gap: 5px; cursor: pointer; }
.cap-size-note { margin: 6px 2px 0; font-size: 10px; color: var(--text-muted, #6b7280); }
`;

  const CHEVRON =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" ' +
    'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
    '<polyline points="6 9 12 15 18 9"/></svg>';

  class CaptureSizeMenu {
    /**
     * @param {object} opts
     * @param {string} opts.storageKey       localStorage key for the selection
     * @param {(settings) => void} [opts.onChange]
     * @param {boolean} [opts.showFrameToggle=true]  hide for 3D, where the
     *        rendered frame already contains the device body
     * @param {boolean} [opts.showFitToggle=true]  hide for 3D: on the
     *        render-3d route `fit` is the screenshot's UV placement on the
     *        device's screen mesh, not canvas placement, so offering
     *        contain/cover there would letterbox the app *inside* the phone
     *        display. Canvas placement in 3D is the camera's job.
     * @param {boolean} [opts.showBackgroundToggle=true]  hide for 3D, where
     *        the render's own background already fills the canvas
     * @param {() => ({width:number,height:number})|null} [opts.sourceSize]
     *        lets the popover show the resolved pixel size per preset
     */
    constructor(opts) {
      const o = opts || {};
      this.storageKey = o.storageKey || 'asc.capture';
      this.onChange = o.onChange || (() => {});
      // All three are read at render time, not captured, so a caller can
      // flip them on the instance when the view changes (2D <-> 3D) and
      // reopen the popover without rebuilding the menu.
      this.showFrameToggle = o.showFrameToggle !== false;
      this.showFitToggle = o.showFitToggle !== false;
      this.showBackgroundToggle = o.showBackgroundToggle !== false;
      this.sourceSize = o.sourceSize || (() => null);
      this.settings = window.Baguette._CaptureSettings
        .restore(safeStorage(), this.storageKey);
      this.root = null;
      this.chip = null;
      this.pop = null;
      this._onDocPointerDown = (event) => {
        if (this.root && !this.root.contains(event.target)) this.close();
      };
      this._onKeyDown = (event) => { if (event.key === 'Escape') this.close(); };
    }

    mount(host) {
      if (!host) return this;
      injectStyle();
      this.root = document.createElement('div');
      this.root.className = 'cap-size';
      this.root.innerHTML =
        '<button type="button" class="cap-size-chip" aria-expanded="false" ' +
        'aria-haspopup="true" title="Capture output size">' +
        '<span data-role="label"></span>' + CHEVRON + '</button>' +
        '<div class="cap-size-pop" hidden role="dialog" aria-label="Capture size"></div>';
      this.chip = this.root.querySelector('.cap-size-chip');
      this.pop = this.root.querySelector('.cap-size-pop');
      this.chip.addEventListener('click', () => this.toggle());
      host.appendChild(this.root);
      this._renderChip();
      return this;
    }

    detach() {
      this.close();
      if (this.root && this.root.parentNode) this.root.parentNode.removeChild(this.root);
      this.root = this.chip = this.pop = null;
    }

    toggle() {
      if (!this.pop) return;
      this.pop.hidden ? this.open() : this.close();
    }

    open() {
      if (!this.pop) return;
      this._renderPopover();
      this.pop.hidden = false;
      this.chip.setAttribute('aria-expanded', 'true');
      document.addEventListener('pointerdown', this._onDocPointerDown, true);
      document.addEventListener('keydown', this._onKeyDown);
    }

    close() {
      if (this.pop) this.pop.hidden = true;
      if (this.chip) this.chip.setAttribute('aria-expanded', 'false');
      document.removeEventListener('pointerdown', this._onDocPointerDown, true);
      document.removeEventListener('keydown', this._onKeyDown);
    }

    /** Replace the selection from code (e.g. restoring a farm tile). */
    apply(changes) {
      this.settings = this.settings.with(changes);
      this.settings.persist(safeStorage(), this.storageKey);
      this._renderChip();
      if (this.pop && !this.pop.hidden) this._renderPopover();
      this.onChange(this.settings);
    }

    _renderChip() {
      if (!this.chip) return;
      const label = this.chip.querySelector('[data-role="label"]');
      if (label) label.textContent = this.settings.size.label;
      this.chip.title = this.settings.size.isNative
        ? 'Capture output size: native'
        : `Capture output size: ${this.settings.size.label} · ${this.settings.fit}`;
    }

    _renderPopover() {
      const CaptureSize = window.Baguette._CaptureSize;
      const source = this.sourceSize() || null;
      const current = this.settings;

      const option = (preset) => {
        const dims = source
          ? (() => {
            const r = preset.resolve(source.width, source.height);
            return r.width && r.height ? `${r.width}×${r.height}` : '';
          })()
          : '';
        return '<button type="button" role="menuitemradio" data-size="' +
          escapeAttr(preset.spec) + '" aria-checked="' +
          (preset.id === current.size.id) + '"><span>' +
          escapeHTML(preset.label) + '</span>' +
          (dims ? '<span class="dim">' + dims + '</span>' : '') + '</button>';
      };

      const seg = (name, values, active) => '<div class="cap-size-seg">' +
        values.map((v) => '<button type="button" data-' + name + '="' + v +
          '" aria-checked="' + (v === active) + '">' +
          v[0].toUpperCase() + v.slice(1) + '</button>').join('') + '</div>';

      const isCustom = current.size.id === 'custom' || current.size.id === 'ratio';
      this.pop.innerHTML =
        '<p class="cap-size-head">Size</p>' +
        '<div class="cap-size-list">' +
          CaptureSize.presets().map(option).join('') +
        '</div>' +
        '<p class="cap-size-head">Custom</p>' +
        '<div class="cap-size-row">' +
          '<input type="text" data-role="custom" placeholder="1920x1080 or 3:2" ' +
          'value="' + escapeAttr(isCustom ? current.size.spec : '') + '">' +
        '</div>' +
        (this.showFitToggle
          ? '<p class="cap-size-head">Fit</p>' +
            '<div class="cap-size-row">' +
            seg('fit', CaptureSize.fits, current.fit) + '</div>'
          : '') +
        (this.showBackgroundToggle
          ? '<p class="cap-size-head">Background</p>' +
            '<div class="cap-size-row">' +
              '<input type="color" data-role="background" value="' +
              escapeAttr(/^#[0-9a-f]{6}$/i.test(current.background)
                ? current.background : '#ffffff') +
              '">' +
              '<label><input type="checkbox" data-role="transparent"' +
              (current.background === 'transparent' ? ' checked' : '') +
              '><span>Transparent</span></label>' +
            '</div>'
          : '') +
        (this.showFrameToggle
          ? '<p class="cap-size-head">Device</p>' +
            '<div class="cap-size-row"><label>' +
            '<input type="checkbox" data-role="frame"' +
            (current.withFrame ? ' checked' : '') + '><span>Include bezel</span>' +
            '</label></div>'
          : '') +
        (current.size.isNative && (this.showFitToggle || this.showBackgroundToggle)
          ? '<p class="cap-size-note">Native keeps the source size — ' +
            [this.showFitToggle ? 'fit' : null,
              this.showBackgroundToggle ? 'background' : null]
              .filter(Boolean).join(' and ') +
            ' ' + (this.showFitToggle && this.showBackgroundToggle ? 'have' : 'has') +
            ' no effect.</p>'
          : '');

      this.pop.querySelectorAll('[data-size]').forEach((button) => {
        button.addEventListener('click', () => {
          this.apply({ size: button.dataset.size });
        });
      });
      this.pop.querySelectorAll('[data-fit]').forEach((button) => {
        button.addEventListener('click', () => {
          this.apply({ fit: button.dataset.fit });
        });
      });

      const custom = this.pop.querySelector('[data-role="custom"]');
      const commitCustom = () => {
        const text = custom.value.trim();
        if (!text) return;
        if (!CaptureSize.parse(text)) {
          custom.value = isCustom ? current.size.spec : '';
          return;
        }
        this.apply({ size: text });
      };
      custom.addEventListener('change', commitCustom);
      custom.addEventListener('keydown', (event) => {
        if (event.key === 'Enter') { event.preventDefault(); commitCustom(); }
      });

      const background = this.pop.querySelector('[data-role="background"]');
      if (background) {
        background.addEventListener('input', (event) => {
          this.apply({ background: event.target.value });
        });
      }
      const transparent = this.pop.querySelector('[data-role="transparent"]');
      if (transparent) {
        transparent.addEventListener('change', (event) => {
          this.apply({ background: event.target.checked ? 'transparent' : '#ffffff' });
        });
      }
      const frame = this.pop.querySelector('[data-role="frame"]');
      if (frame) {
        frame.addEventListener('change', (event) => {
          this.apply({ withFrame: event.target.checked });
        });
      }
    }
  }

  // ── helpers ──────────────────────────────────────────────────

  function injectStyle() {
    if (document.getElementById(STYLE_ID)) return;
    const style = document.createElement('style');
    style.id = STYLE_ID;
    style.textContent = CSS;
    document.head.appendChild(style);
  }

  // Safari private browsing throws on localStorage access; CaptureSettings
  // already swallows that, this just keeps the property lookup itself safe.
  function safeStorage() {
    try {
      return window.localStorage || NULL_STORAGE;
    } catch (_) {
      return NULL_STORAGE;
    }
  }

  const NULL_STORAGE = { getItem: () => null, setItem: () => {} };

  function escapeHTML(text) {
    return String(text).replace(/[&<>"]/g, (c) => (
      { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]
    ));
  }

  const escapeAttr = escapeHTML;

  window.CaptureSizeMenu = CaptureSizeMenu;
})();
