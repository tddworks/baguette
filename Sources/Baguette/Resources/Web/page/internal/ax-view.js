// The accessibility inspector over the device's screen: hover to see an
// element, click to pin it in its panel — the device's UI tree, from the
// server. What it needs of the page is its port: { sim, live() }.
// Out of page/device-page.js (design §4).

export function axView(page) {
  let axInspector = null;
  // Lazy-mounts the AXInspector once a surface + session are ready.
  // Re-runs on `remountFrame()` because the screen DOM and the
  // session both change underneath it.
  //
  // Focus-mode UX:
  //   - The inspector has no inline UI host. Enable/disable is
  //     driven by the `nativeAxToggle` toolbar button.
  //   - Selection details surface in the `nativeAxHost` floating
  //     panel, which is hidden until the user clicks an element.
  function mountAxInspector() {
    if (axInspector) {
      try { axInspector.detach(); } catch (_) { /* ignore */ }
      axInspector = null;
    }
    if (!window.AXInspector || !page.sim) return;
    const panel = document.getElementById('nativeAxHost');
    axInspector = new window.AXInspector({
      // No `host` — toolbar drives enable/disable, panel surfaces selection.
      screenArea: page.sim.screenArea,
      send: (payload) => page.live().session && page.live().session.send(payload),
      // AX inspector reads `{w, h}`; SDK Screen exposes `{width, height}`.
      getDeviceSize: () => ({ w: page.sim.screen.size.width, h: page.sim.screen.size.height }),
      onSelect: (node) => renderAxPanel(panel, node),
      onEnableChange: (enabled) => {
        const btn = document.getElementById('nativeAxToggle');
        if (btn) btn.classList.toggle('active', enabled);
        if (!enabled && panel) {
          panel.removeAttribute('data-open');
          panel.innerHTML = '';
        }
      },
    });
  }

  // Surface a selected AX node in the floating `#nativeAxHost`
  // panel. Wraps the inspector's static selection renderer with a
  // header (title + close) so the panel can be dismissed without
  // disabling the inspector itself.
  function renderAxPanel(panel, node) {
    if (!panel) return;
    if (!node) {
      panel.removeAttribute('data-open');
      panel.innerHTML = '';
      return;
    }
    panel.setAttribute('data-open', 'true');
    panel.innerHTML =
        '<div class="ax-host-head">' +
        '<span>Element</span>' +
        '<button class="ax-host-close" data-role="ax-close" aria-label="Dismiss">×</button>' +
        '</div>' +
        '<div data-role="ax-body"></div>';
    panel.querySelector('[data-role="ax-close"]').addEventListener('click', () => {
      panel.removeAttribute('data-open');
      panel.innerHTML = '';
    });
    window.AXInspector.renderSelectionInto(
        panel.querySelector('[data-role="ax-body"]'),
        node,
        {
          send: (payload) => page.live().session && page.live().session.send(payload),
          getDeviceSize: () => ({ w: page.sim.screen.size.width, h: page.sim.screen.size.height }),
        }
    );
  }
  /** Turn the inspector on or off. */
  function toggleAx() {
    if (!axInspector) return;
    if (axInspector.isEnabled()) axInspector.disable();
    else axInspector.enable();
  }

  /** The page is going: the inspector lets go. */
  function detachAx() {
    if (axInspector) axInspector.detach();
  }
  return {
    /** The inspector, once mounted. */
    get inspector() { return axInspector; },
    mountAxInspector, toggleAx, detachAx,
  };
}

if (typeof window !== 'undefined') {
  window.Baguette = window.Baguette || {};
  window.Baguette._AxView = { axView };
}
