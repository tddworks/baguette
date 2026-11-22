// Handheld mode: the stream held in the hand — open the page on a phone
// and the live screen takes the whole view, no bezel, no workbench, the
// screen kept awake, with a floating button for the rest. HandheldMode
// (handheld/handheld-mode.js) answers whether, where and how big; this
// paints it. What it needs of the page is its port:
// { currentOrientation, device, foldable, sim, refreshToolbarScroll(), toggle3D() }.
// Out of page/device-page.js (design §4). docs/features/handheld/README.md.
import { HandheldMode } from '../../handheld/handheld-mode.js';
import { HandheldButton } from '../../handheld/handheld-button.js';

export function handheldView(page) {
  let handheld = false;       // the stream held in the hand — see enterHandheld
  let handheldIdleTimer = null; // fades the floating button when left alone
  let handheldButtonWired = false;
  let wakeLock = null;        // keeps a phone's screen on while it is the simulator
  let handheldViewport = null; // the viewport <meta> content handheld replaced
  let handheldBackground = null; // the <body> background handheld replaced
  let handheldHintTimer = null; // fades the Add-to-Home-Screen hint
  // --- Handheld ------------------------------------------------------
  // The stream held in the hand: open this page on a phone and the live
  // screen takes the whole view, no bezel, no workbench, the way the
  // phone in your hand would look. HandheldMode (handheld/handheld-mode.js)
  // answers whether, where and how big; this paints it. The CSS under
  // `[data-handheld]` in page/device-page.html does the rest. See
  // docs/features/handheld/README.md.

  function handheldMode() {
    return HandheldMode;
  }

  /** Launched from a Home Screen icon — no browser bars around the page. */
  function launchedStandalone() {
    return (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches)
        || (window.matchMedia && window.matchMedia('(display-mode: fullscreen)').matches)
        || window.navigator.standalone === true;
  }

  function handheldWanted() {
    const mode = handheldMode();
    return !!mode && mode.wanted({ search: location.search, standalone: launchedStandalone() });
  }

  /**
   * Hand the screen the whole view. A foldable has no flat screen to
   * hand over — its main view is the 3D book — and without the SDK's
   * definition there is no screen at all, so both stay on the bench.
   *
   * `fullscreen` asks the browser to drop its own bars too. That needs
   * the click that got us here, and only Android / desktop browsers
   * honour it for a page; on an iPhone every browser is WebKit and says
   * no, so the Home Screen icon is the way there (see the README).
   */
  function enterHandheld({ fullscreen = true } = {}) {
    const mode = handheldMode();
    const view = document.getElementById('simNativeView');
    if (!mode || !view || !page.sim || page.foldable || handheld) return;
    if (view.getAttribute('data-render3d') === 'open') page.toggle3D();
    handheld = true;
    view.setAttribute('data-handheld', '');
    history.replaceState(history.state, '', mode.href(location.href, true));
    coverViewport(true);
    wireHandheldButton();
    layoutHandheld();
    wakeHandheldButton();
    window.addEventListener('resize', layoutHandheld);
    if (window.visualViewport) window.visualViewport.addEventListener('resize', layoutHandheld);
    darkenBrowser(true);
    holdScreenAwake();
    const route = mode.fullscreenRoute({
      standalone: launchedStandalone(),
      pageFullscreen: !!(document.fullscreenEnabled || document.webkitFullscreenEnabled),
    });
    if (route === 'browser' && fullscreen) {
      const el = document.documentElement;
      const request = el.requestFullscreen || el.webkitRequestFullscreen;
      try {
        const pending = request.call(el, { navigationUI: 'hide' });
        if (pending && pending.catch) pending.catch(() => { /* refused — handheld still fills the page */ });
      } catch (_) { /* refused — handheld still fills the page */ }
    } else if (route === 'home-screen') {
      showHomeScreenHint();
    }
  }

  function exitHandheld() {
    const mode = handheldMode();
    const view = document.getElementById('simNativeView');
    if (!handheld || !view) return;
    handheld = false;
    view.removeAttribute('data-handheld');
    view.style.removeProperty('--nv-hh-w');
    view.style.removeProperty('--nv-hh-h');
    setHandheldMenu(false);
    if (mode) history.replaceState(history.state, '', mode.href(location.href, false));
    if (!launchedStandalone()) coverViewport(false);
    darkenBrowser(false);
    hideHomeScreenHint();
    window.removeEventListener('resize', layoutHandheld);
    if (window.visualViewport) window.visualViewport.removeEventListener('resize', layoutHandheld);
    releaseScreenAwake();
    const fsEl = document.fullscreenElement || document.webkitFullscreenElement;
    if (fsEl) {
      const exit = document.exitFullscreen || document.webkitExitFullscreen;
      if (exit) {
        try {
          const pending = exit.call(document);
          if (pending && pending.catch) pending.catch(() => {});
        } catch (_) { /* already out */ }
      }
    }
    if (page.refreshToolbarScroll) page.refreshToolbarScroll();
  }

  /** Size the screen box to the view, for the orientation it shows. */
  function layoutHandheld() {
    const mode = handheldMode();
    const view = document.getElementById('simNativeView');
    if (!handheld || !mode || !view || !page.sim || !page.sim.screen) return;
    const rect = page.sim.screen.def.rect;
    const box = mode.fit({
      viewport: { width: window.innerWidth, height: window.innerHeight },
      screen: { width: rect.width, height: rect.height },
      orientation: page.currentOrientation,
    });
    view.style.setProperty('--nv-hh-w', box.width + 'px');
    view.style.setProperty('--nv-hh-h', box.height + 'px');
    placeHandheldButton();
  }

  /**
   * `viewport-fit=cover` lets the screen run under a Home Screen
   * launch's translucent status bar and round the notch, instead of
   * stopping at the safe area. Workbench layout was never drawn for
   * that, so it is handheld's alone and handed back on the way out.
   */
  function coverViewport(on) {
    const meta = document.querySelector('meta[name="viewport"]');
    if (!meta) return;
    if (on) {
      if (handheldViewport === null) handheldViewport = meta.getAttribute('content') || '';
      meta.setAttribute('content', 'width=device-width,initial-scale=1,viewport-fit=cover');
    } else if (handheldViewport !== null) {
      meta.setAttribute('content', handheldViewport);
      handheldViewport = null;
    }
  }

  /**
   * The bars a phone browser keeps — Safari's status-bar strip and
   * toolbar, Chrome's — tint themselves from the page background and
   * `theme-color`. The workbench's light page made them a pale frame
   * around a black stage; black makes them recede into the bezel.
   */
  function darkenBrowser(on) {
    let meta = document.querySelector('meta[name="theme-color"]');
    if (on) {
      if (handheldBackground === null) handheldBackground = document.body.style.background;
      document.body.style.background = '#000';
      document.documentElement.style.background = '#000';
      if (!meta) {
        meta = document.createElement('meta');
        meta.name = 'theme-color';
        meta.dataset.handheld = '';
        document.head.appendChild(meta);
      }
      meta.setAttribute('content', '#000000');
    } else {
      if (handheldBackground !== null) document.body.style.background = handheldBackground;
      handheldBackground = null;
      document.documentElement.style.background = '';
      if (meta && meta.dataset.handheld !== undefined) meta.remove();
    }
  }

  /**
   * On an iPhone the bars can't go from inside a tab; a Home Screen
   * icon is the way to a screen with nothing around it. Said once per
   * browser — after that it's known, and it would only be in the way.
   */
  function showHomeScreenHint() {
    const hint = document.getElementById('nativeHandheldHint');
    const key = 'baguette.handheld.homeScreenHintSeen';
    if (!hint) return;
    try { if (localStorage.getItem(key)) return; localStorage.setItem(key, '1'); } catch (_) {}
    hint.hidden = false;
    clearTimeout(handheldHintTimer);
    handheldHintTimer = setTimeout(hideHomeScreenHint, 9000);
  }

  function hideHomeScreenHint() {
    const hint = document.getElementById('nativeHandheldHint');
    clearTimeout(handheldHintTimer);
    handheldHintTimer = null;
    if (hint) hint.hidden = true;
  }

  /**
   * A phone that dims and locks in the middle of a session isn't
   * acting like the simulator. The browser drops the lock whenever the
   * page is hidden, so it is taken again each time the page comes back.
   */
  let wakeLockAsked = false;
  async function holdScreenAwake() {
    if (!handheld || wakeLock || wakeLockAsked || !navigator.wakeLock || document.visibilityState !== 'visible') return;
    wakeLockAsked = true;
    try {
      const lock = await navigator.wakeLock.request('screen');
      // Handheld ended while the lock was being granted: it isn't ours to keep.
      if (handheld) wakeLock = lock; else lock.release().catch(() => {});
    } catch (_) { /* refused (low battery, no gesture yet) — the screen may dim */ }
    wakeLockAsked = false;
  }

  function releaseScreenAwake() {
    if (wakeLock) {
      wakeLock.release().catch(() => {});
      wakeLock = null;
    }
  }

  document.addEventListener('visibilitychange', () => { void holdScreenAwake(); });

  // --- The floating button --------------------------------------------
  // HandheldButton (handheld/handheld-button.js) decides where it rests;
  // this drags and paints it. The spot is kept per browser, so a Home
  // Screen icon opens with the button where it was left.

  const HANDHELD_BUTTON_KEY = 'baguette.handheld.button';
  const HANDHELD_BUTTON_SIZE = 56;
  const HANDHELD_BUTTON_MARGIN = 6;

  function handheldButtonGeometry() {
    const ui = document.getElementById('nativeHandheldUI');
    const pad = ui ? getComputedStyle(ui) : null;
    const px = (v) => parseFloat(v) || 0;
    return {
      viewport: { width: window.innerWidth, height: window.innerHeight },
      size: HANDHELD_BUTTON_SIZE,
      margin: HANDHELD_BUTTON_MARGIN,
      // The phone's status bar and home indicator, as the safe area
      // `.handheld-ui` carries in its padding.
      insets: pad
        ? { top: px(pad.paddingTop), right: px(pad.paddingRight),
            bottom: px(pad.paddingBottom), left: px(pad.paddingLeft) }
        : { top: 0, right: 0, bottom: 0, left: 0 },
    };
  }

  function storedHandheldSpot() {
    try {
      const spot = JSON.parse(localStorage.getItem(HANDHELD_BUTTON_KEY) || 'null');
      if (spot && (spot.side === 'left' || spot.side === 'right') && typeof spot.yNorm === 'number') {
        return spot;
      }
    } catch (_) { /* unreadable — fall back */ }
    // Right edge, below the middle: where a right thumb rests, and clear
    // of the status bar and the home indicator either way.
    return { side: 'right', yNorm: 0.62 };
  }

  function placeHandheldButton() {
    const fab = document.getElementById('nativeHandheldFab');
    const button = HandheldButton;
    if (!handheld || !fab || !button) return;
    const at = button.place(Object.assign({}, storedHandheldSpot(), handheldButtonGeometry()));
    fab.style.left = at.left + 'px';
    fab.style.top = at.top + 'px';
  }

  /** Full strength now, faded after a few seconds of being left alone. */
  function wakeHandheldButton() {
    const fab = document.getElementById('nativeHandheldFab');
    if (!fab) return;
    fab.removeAttribute('data-idle');
    clearTimeout(handheldIdleTimer);
    handheldIdleTimer = setTimeout(() => fab.setAttribute('data-idle', ''), 3000);
  }

  /**
   * Press, drag, lift. A press that lifts where it landed opens the
   * menu; one that travels carries the button and drops it on the
   * nearer side edge. Pointer events cover finger and mouse alike, and
   * the capture keeps a fast drag from slipping off the button.
   */
  function wireHandheldButton() {
    const fab = document.getElementById('nativeHandheldFab');
    const button = HandheldButton;
    if (handheldButtonWired || !fab || !button) return;
    handheldButtonWired = true;
    let press = null;
    // A drag ends in a click too; that one isn't a press of the button.
    let swallowClick = false;
    // Activation — a tap, the keyboard, assistive tech — opens the menu.
    fab.addEventListener('click', (e) => {
      e.stopPropagation();
      if (swallowClick) { swallowClick = false; return; }
      setHandheldMenu(true);
    });
    fab.addEventListener('pointerdown', (e) => {
      e.preventDefault();
      e.stopPropagation();
      const r = fab.getBoundingClientRect();
      press = { id: e.pointerId, x: e.clientX, y: e.clientY,
                dx: e.clientX - r.left, dy: e.clientY - r.top, dragging: false };
      try { fab.setPointerCapture(e.pointerId); } catch (_) {}
      wakeHandheldButton();
    });
    fab.addEventListener('pointermove', (e) => {
      if (!press || e.pointerId !== press.id) return;
      if (!press.dragging && button.isTap({ dx: e.clientX - press.x, dy: e.clientY - press.y })) return;
      press.dragging = true;
      fab.setAttribute('data-dragging', '');
      fab.style.left = (e.clientX - press.dx) + 'px';
      fab.style.top = (e.clientY - press.dy) + 'px';
    });
    const lift = (e) => {
      if (!press || e.pointerId !== press.id) return;
      const was = press;
      press = null;
      fab.removeAttribute('data-dragging');
      if (!was.dragging) return;   // a tap: its click opens the menu
      swallowClick = true;
      const geometry = handheldButtonGeometry();
      const spot = button.rest({
        x: e.clientX - was.dx + HANDHELD_BUTTON_SIZE / 2,
        y: e.clientY - was.dy + HANDHELD_BUTTON_SIZE / 2,
        viewport: geometry.viewport, size: HANDHELD_BUTTON_SIZE,
      });
      try { localStorage.setItem(HANDHELD_BUTTON_KEY, JSON.stringify(spot)); } catch (_) {}
      placeHandheldButton();
      wakeHandheldButton();
    };
    fab.addEventListener('pointerup', lift);
    // The browser took the press away: nothing was pressed, and the button
    // goes back where it was.
    fab.addEventListener('pointercancel', (e) => {
      if (!press || e.pointerId !== press.id) return;
      press = null;
      fab.removeAttribute('data-dragging');
      placeHandheldButton();
    });
  }

  /** Open (or close) the menu over its scrim — offering only what the
   *  device can do (an item's `data-needs`: a Mac share doesn't turn). */
  function setHandheldMenu(open) {
    document.querySelectorAll('#nativeHandheldUI [data-needs]').forEach((item) => {
      item.hidden = !page.device.can(item.dataset.needs);
    });
    const ui = document.getElementById('nativeHandheldUI');
    if (!ui) return;
    ui.setAttribute('data-open', open ? 'true' : 'false');
    const fab = document.getElementById('nativeHandheldFab');
    if (fab) fab.setAttribute('aria-expanded', open ? 'true' : 'false');
    if (!open) wakeHandheldButton();
  }

  return { coverViewport, enterHandheld, exitHandheld, handheldWanted, hideHomeScreenHint, launchedStandalone, layoutHandheld, setHandheldMenu };
}

