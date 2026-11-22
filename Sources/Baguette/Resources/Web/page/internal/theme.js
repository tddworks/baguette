// The page's theme: light or dark, picked by the pill in the corner and
// remembered, else following the OS; the live 3D view's background follows
// it. What it needs of the page is its port: { render3DPanel }.
// Out of page/device-page.js (design §4).

export function theme(page) {
  // Theme toggle. Three logical states — "auto" (no manual pin,
  // follow OS via prefers-color-scheme), "light", "dark". The pill
  // in the bottom-right corner cycles light ↔ dark; we don't
  // expose "auto" from the click cycle because the icon set has
  // only two states. The user can reset to auto by deleting the
  // localStorage key in DevTools if needed.
  const THEME_KEY = 'baguette.simTheme';

  function applyStoredTheme() {
    const stored = localStorage.getItem(THEME_KEY);
    if (stored === 'light' || stored === 'dark') {
      setTheme(stored);
    }
  }

  function currentTheme() {
    const root = document.getElementById('simNativeView');
    const pinned = root && root.getAttribute('data-theme');
    if (pinned === 'light' || pinned === 'dark') return pinned;
    return window.matchMedia('(prefers-color-scheme: light)').matches
        ? 'light' : 'dark';
  }

  function live3DBackground() {
    const root = document.getElementById('simNativeView');
    const computed = root
        ? getComputedStyle(root).getPropertyValue('--nv-page-bg').trim()
        : '';
    if (/^#[0-9a-f]{6}$/i.test(computed)) return computed;
    return currentTheme() === 'light' ? '#f1f3f6' : '#1a1a1f';
  }

  function setTheme(theme) {
    const root = document.getElementById('simNativeView');
    if (!root) return;
    if (theme === 'light' || theme === 'dark') {
      root.setAttribute('data-theme', theme);
      localStorage.setItem(THEME_KEY, theme);
    } else {
      root.removeAttribute('data-theme');
      localStorage.removeItem(THEME_KEY);
    }
    if (page.render3DPanel && root.getAttribute('data-render3d') === 'open') {
      page.render3DPanel.setBackground(live3DBackground());
    }
  }

  // Open (or reopen) a StreamSession on the existing surface for a
  // given wire format. Tearing down + restarting is the cheapest way
  // to swap formats — the WS protocol is per-connection and the
  // server's makeStream(...) is keyed at session open.
  // Same text-frame router as page/devices-stream.js: hand JSON envelopes to
  // the inspector first, then claim paste_result; anything nobody
  // claims falls through to the decoder's error logger.
  return { applyStoredTheme, currentTheme, live3DBackground, setTheme };
}

if (typeof window !== 'undefined') {
  window.Baguette = window.Baguette || {};
  window.Baguette._Theme = { theme };
}
