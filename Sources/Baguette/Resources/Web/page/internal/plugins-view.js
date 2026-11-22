// The plugins rail: what plugins installed on this host offer the device
// (/plugins.json), on the right edge — a row taps the device, boxes an
// element over the live screen, or runs a command. What it needs of the
// page is its port: { udid, sim, live(), rightRails() }.
// Out of page/device-page.js (design §4).

export function pluginsView(page) {
  let pluginPanels = null;   // PluginPanels — manifest-declared plugin UI
  // Plugin contributions — a separate rail on the right edge, drawn by
  // the host from /plugins.json. Kept apart from the device toolbar on
  // purpose: baguette ships the toolbar, plugins are code you
  // installed, and the split is a trust signal. `onHighlight` converts
  // a row's device-point frame into a box over the live screen; the
  // frame arrives in the same units as gesture coordinates, so the
  // only maths is the display scale.
  function mountPlugins() {
    if (!window.PluginPanels || !page.sim) return;
    pluginPanels = new window.PluginPanels({
      udid: page.udid,
      // The shared right-edge stack, below baguette's own screens rail —
      // two rails claiming the same centred slot would sit on top of
      // each other. The panel and flyout inside stay `position: fixed`
      // and are unaffected by the stack; see `.right-rails`.
      mount: page.rightRails(),
      // The add-a-bakery modal covers the page, so it hangs off the
      // view root instead. `.right-rails` is `position: fixed` and so a
      // stacking context of its own whatever its `z-index` says —
      // anything mounted in there composites at the rail's level, which
      // is below the device.
      modalMount: document.getElementById('simNativeView') || document.body,
      isBooted: () => true,
      onHighlight: (frame) => paintPluginHighlight(frame),
      onTap: (point) => tapForPlugin(point),
      log: (msg) => console.log('[plugin]', msg),
    });
    pluginPanels.load();
  }

  // A `rowAction: "tap"` row, dispatched down the same socket every
  // other gesture uses. Wire shape matches GestureRegistry's `tap`:
  // device-point coordinates plus the device-point screen size — the
  // row's frame already arrives in that space, so there's nothing to
  // convert.
  function tapForPlugin(point) {
    if (!page.live().session || !page.sim || !page.sim.screen || !page.sim.screen.size) return;
    const size = page.sim.screen.size;
    page.live().session.send({
      type: 'tap',
      x: point.x, y: point.y,
      width: size.width, height: size.height,
    });
  }

  function paintPluginHighlight(frame) {
    let box = document.getElementById('nativePluginHighlight');
    if (!frame) { if (box) box.remove(); return; }
    if (!page.sim || !page.sim.screenArea) return;

    const area = page.sim.screenArea;
    const device = page.sim.screen.size;
    if (!device || !device.width || !device.height) return;
    const scaleX = area.clientWidth / device.width;
    const scaleY = area.clientHeight / device.height;

    if (!box) {
      box = document.createElement('div');
      box.id = 'nativePluginHighlight';
      box.className = 'plugin-highlight';
      area.appendChild(box);
    }
    box.style.left   = (frame.x * scaleX) + 'px';
    box.style.top    = (frame.y * scaleY) + 'px';
    box.style.width  = (frame.width * scaleX) + 'px';
    box.style.height = (frame.height * scaleY) + 'px';
  }
  return {
    /** The plugin panels, once mounted. */
    get panels() { return pluginPanels; },
    mountPlugins,
  };
}

if (typeof window !== 'undefined') {
  window.Baguette = window.Baguette || {};
  window.Baguette._PluginsView = { pluginsView };
}
