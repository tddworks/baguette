// Simulator — the facade. Composes Bezel + Screen + Buttons (+
// optional Crown / Keyboard / Remote in later slices) from a
// SimulatorDefinition; exposes `mount(container)` as the entire
// view-side API consumer pages need.
//
// First-principle shape: a simulator stands in for a physical
// device; it has parts. Each part is its own class. The Simulator
// facade owns lifecycle (attach/detach) and composition; it has no
// per-part behaviour of its own.
//
// Adding a new part type (Crown, Remote, Pencil) is:
//   1. Add the field to the Swift SimulatorDefinition
//   2. Add a new parts/<thing>.js with a class
//   3. Instantiate here when `def.<thing>` is present
// Consumer pages don't change.
(function (root) {
  'use strict';

  class Simulator {
    /**
     * @param {object} def       SimulatorDefinition (from definition.json)
     * @param {Transport} transport
     */
    constructor(def, transport, { getOrientation, log } = {}) {
      this.def = def;
      this.transport = transport;
      this.identity = def.identity;
      this.getOrientation = getOrientation || (() => 'portrait');
      this.log = log || (() => {});
      this.screen   = new root.Baguette._Screen(def.screen, transport,
                          { getOrientation: this.getOrientation, log: this.log });
      this.buttons  = (def.buttons || []).map(b => new root.Baguette._Button(b, transport));
      // Optional parts: instantiated iff the definition carries the
      // field. Apple TV omits `keyboard`; Apple Watch will populate
      // `crown` when that part lands.
      this.keyboard = def.keyboard
        ? new root.Baguette._Keyboard(def.keyboard, transport)
        : null;
      this._bezel = new root.Baguette._Bezel(def.screen);
    }

    /** Render the simulator into the container, fully interactive. */
    mount(container) {
      this._bezel.mount(container);
      this.screen.bindDOM({
        screenArea: this._bezel.screenArea,
        canvas:     this._bezel.canvas,
      });
      for (const b of this.buttons) b.mount(this._bezel.wrapper);
      if (this.keyboard) this.keyboard.attach(this._bezel.screenArea);
    }

    /** Tear everything down. Idempotent. */
    detach() {
      if (this.keyboard) this.keyboard.detach();
      for (const b of this.buttons) b.detach();
      this.screen.detach();
      this._bezel.detach();
    }

    /** Convenience lookup: `sim.button('powerButton')`. */
    button(id) { return this.buttons.find(b => b.id === id); }

    /** Send a hardware-button press by WIRE name (`"home"`,
     *  `"lock"`, `"power"`, `"app-switcher"`, …) — covers virtual
     *  buttons that have no overlay (sidebar / toolbar callbacks). */
    pressButton(wire, opts) {
      this.transport.button({ type: 'button', button: wire }, opts);
    }

    /** Convenience: send raw text through the keyboard. No-op
     *  if this device has no keyboard part. */
    type(text) { if (this.keyboard) this.keyboard.type(text); }

    /** Pinch-overlay container — exposed for callers that need to
     *  composite the overlay dots into a recording (BrowserRecorder). */
    get pinchOverlayContainer() {
      const o = this.screen._overlay;
      return o ? o.container : null;
    }

    /** Frame canvas — provided so the existing StreamSession can
     *  keep painting frames into the SDK's screen while we migrate. */
    get canvas() { return this._bezel.canvas; }
    /** Screen area — clickable element exposed for legacy code paths
     *  (axInspector overlay, ripple positioning, …). */
    get screenArea() { return this._bezel.screenArea; }
  }

  root.Baguette = root.Baguette || {};
  root.Baguette._Simulator = Simulator;
})(window);
