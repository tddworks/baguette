// The toolbar's layout on the page: wiring it once the page is up —
// clusters built, scrolled or folded as the row allows, re-laid on resize —
// the floating panels placed below it, and the device's header (its
// abilities badge, its frame picker). What it needs of the page is its port:
// { device, deviceAbilities, toolbar() }. Out of page/device-page.js (§4).

import { DeviceBadge } from '../../device/device-badge.js';

export function toolbarLayout(page) {
  /** Until the toolbar is wired, there is nothing to lay out. */
  let refreshing = () => {};
  /** Lay the toolbar out again (it scrolls or folds as the row allows). */
  function refresh() { refreshing(); }

  /// A device that isn't a simulator has a badge saying what it can do, from the abilities
  /// the server lists for it. The controls themselves already follow
  /// those abilities (`buildToolbarClusters`), for every device.
  function applyDeviceModeChrome() {
    if (!page.device.badge) return;
    const osEl = document.getElementById('nativeDeviceOS');
    if (osEl && !document.getElementById('nativeDeviceBadge')) {
      const badge = document.createElement('span');
      badge.id = 'nativeDeviceBadge';
      const words = DeviceBadge.of(page.deviceAbilities || []);
      badge.textContent = words.text;
      badge.title = words.title;
      badge.style.cssText =
        'margin-left:8px;padding:2px 8px;border:1px solid #fde68a;' +
        'border-radius:99px;background:#fef3c7;color:#92400e;' +
        'font-size:10.5px;font-weight:700;letter-spacing:.03em;white-space:nowrap';
      osEl.insertAdjacentElement('afterend', badge);
    }
    if (page.device.frame.picker) page.device.frame.picker.mount(document.getElementById('nativeDeviceBadge'));
  }

  /**
   * Start the floating panels (status bar, network, defaults, …) below
   * the toolbar wherever it actually is.
   *
   * The toolbar rides the device's vertically centred column, so a
   * window taller than the device needs pushes it down past the panels'
   * old fixed `top: 84px` and the bar covered each panel's first row.
   * Watching the view as well as the bar catches a window resize that
   * re-centres the column without changing the bar's own size.
   */
  function placeFloatingPanels() {
    const view = document.getElementById('simNativeView');
    const bar = document.querySelector('#simNativeView .top-bar');
    if (!view || !bar || typeof ResizeObserver === 'undefined') return;
    const place = () => {
      const below = Math.round(bar.getBoundingClientRect().bottom) + 24;
      view.style.setProperty('--nv-panel-top', Math.max(84, below) + 'px');
    };
    const observer = new ResizeObserver(place);
    observer.observe(view);
    observer.observe(bar);
    // The device frame settling (bezel image, rotation) moves the bar
    // without resizing either element.
    const frame = document.getElementById('nativeDeviceFrame');
    if (frame) observer.observe(frame);
    place();
  }

  function wireToolbarScroll() {
    if (!page.toolbar().buildToolbarClusters()) return;
    applyDeviceModeChrome();

    document.addEventListener('click', (event) => {
      const btn = event.target.closest('#simNativeView .tb-fold-btn');
      if (btn) {
        const pop = btn.parentElement.querySelector('.tb-fold-pop');
        const open = btn.getAttribute('aria-expanded') === 'true';
        page.toolbar().closeFoldMenus();
        if (!open) {
          page.toolbar().refreshFoldMenus();   // as the controls are now, not as they were laid out
          pop.hidden = false;
          btn.setAttribute('aria-expanded', 'true');
        }
        return;
      }
      const summary = event.target.closest('#simNativeView .tb-acc > summary');
      if (summary) {
        // `name=` handles this in Chrome 120+/Safari 17.4+; do it by
        // hand so older engines behave the same.
        const self = summary.parentElement;
        setTimeout(() => {
          if (!self.open) return;
          self.parentElement.querySelectorAll('.tb-acc').forEach((d) => {
            if (d !== self) d.open = false;
          });
        }, 0);
        return;
      }
      if (!event.target.closest('#simNativeView .tb-fold')) page.toolbar().closeFoldMenus();
    });

    const layoutToolbar = () => page.toolbar().layoutToolbar();
    refreshing = layoutToolbar;
    window.addEventListener('resize', layoutToolbar);
    placeFloatingPanels();
    // Re-measure once layout settles (fonts, device frame, format pills).
    requestAnimationFrame(layoutToolbar);
    setTimeout(layoutToolbar, 400);
  }

  return { wireToolbarScroll, refresh };
}

