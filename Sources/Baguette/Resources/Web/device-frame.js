// DeviceFrame — pure DOM construction for the bezel + screen overlay.
//
//   const frame = new DeviceFrame({ udid, layout, actionable, onPress });
//   const surface = frame.mount(document.getElementById('simDeviceFrame'));
//   //   surface.screenArea — focus + click target
//   //   surface.canvas     — the drawing surface (replace it if you
//   //                        want a different element)
//   //   surface.frameImg   — the rasterized bezel <img>
//   //   surface.bezelButtons — BezelButtons instance, present only
//   //                          when `actionable` is true
//
// Layout comes from `/simulators/<udid>/chrome.json` (DeviceKit-sourced
// composite size + screen rect + inner corner radius). When `layout`
// is null the bezel image is hidden and the screen fills the area —
// that's the right behaviour for Apple TV / watchOS where DeviceKit
// has no chrome bundle.
//
// `actionable` (default false) swaps the bezel for the buttons-less
// variant (`bezel.png?buttons=false`) and overlays each chrome button
// as its own animatable DOM element via `BezelButtons`. Hardware-
// button presses fire `onPress(name, durationSeconds)` so the host
// page can forward the real hold time to SimInput — needed for iOS
// long-press semantics like the action button's "Hold for Ring".
(function () {
  'use strict';

  function DeviceFrame({ udid, layout, actionable, onPress }) {
    this.udid = udid;
    this.layout = layout;
    this.actionable = !!actionable;
    this.onPress = onPress || (() => {});
  }

  DeviceFrame.prototype.mount = function (container) {
    container.innerHTML = '';
    const wrapper = document.createElement('div');
    wrapper.style.cssText = 'position:relative;display:inline-block;max-height:70vh;';

    // DeviceKit composite PDFs render their screen area as opaque
    // dark "off" glass (intended for layering UNDER the live screen,
    // matching how Xcode previews the device). The legacy hand-rolled
    // PNGs had a transparent screen cutout, so the old plugin put the
    // bezel on top. With DeviceKit data we layer the screen *above*
    // the bezel and clip it to the inner corner radius — same Z order
    // as Apple's own Simulator window.
    //
    // In actionable mode we ask for `?buttons=false` so the bezel
    // image carries only the device body — `BezelButtons` overlays
    // each hardware button as its own animatable <img> over the
    // wrapper.
    const frameImg = document.createElement('img');
    const bezelQuery = this.actionable ? '?buttons=false' : '';
    frameImg.src = `/simulators/${encodeURIComponent(this.udid)}/bezel.png${bezelQuery}`;
    frameImg.draggable = false;
    frameImg.alt = '';
    frameImg.style.cssText =
      'display:block;height:100%;max-height:70vh;pointer-events:none;position:relative;z-index:1;';
    frameImg.onerror = () => { frameImg.style.display = 'none'; };

    const screenArea = document.createElement('div');
    screenArea.style.cssText = 'position:absolute;overflow:hidden;cursor:crosshair;z-index:2;';
    screenArea.tabIndex = 0;
    screenArea.style.outline = 'none';

    const canvas = document.createElement('canvas');
    canvas.id = 'simStreamCanvas';
    canvas.style.cssText =
      'display:block;width:100%;height:100%;object-fit:fill;image-rendering:high-quality;';
    screenArea.appendChild(canvas);

    wrapper.appendChild(screenArea);
    wrapper.appendChild(frameImg);

    if (this.layout && this.layout.composite && this.layout.screen) {
      // chrome.json reports the *merged* composite size + screen
      // rect (both shifted by `buttonMargins` so they line up with
      // the merged bezel.png). In actionable mode the bezel <img>
      // is the BARE composite (margins not baked in), so we have
      // to subtract the margins back out for percentages to land
      // on the right pixels.
      const m = this.layout.buttonMargins || { top: 0, left: 0, bottom: 0, right: 0 };
      const useMargin = this.actionable;
      const cw = this.layout.composite.width  - (useMargin ? (m.left || 0) + (m.right  || 0) : 0);
      const ch = this.layout.composite.height - (useMargin ? (m.top  || 0) + (m.bottom || 0) : 0);
      const s = this.layout.screen;
      const sx = s.x - (useMargin ? (m.left || 0) : 0);
      const sy = s.y - (useMargin ? (m.top  || 0) : 0);
      screenArea.style.left   = (sx       / cw * 100) + '%';
      screenArea.style.top    = (sy       / ch * 100) + '%';
      screenArea.style.width  = (s.width  / cw * 100) + '%';
      screenArea.style.height = (s.height / ch * 100) + '%';
      // CSS `border-radius: X%` is *elliptical* — horizontal radius
      // tracks width, vertical tracks height. On a tall phone screen
      // a single percentage stretches into an oval. Use the `H% / V%`
      // form so both axes resolve to the same composite-pixel radius.
      const r = this.layout.innerCornerRadius || 0;
      const hPct = (r / s.width)  * 100;
      const vPct = (r / s.height) * 100;
      screenArea.style.borderRadius = `${hPct}% / ${vPct}%`;
    } else {
      frameImg.style.display = 'none';
      screenArea.style.left = '0';
      screenArea.style.top = '0';
      screenArea.style.width = '100%';
      screenArea.style.height = '100%';
    }

    container.appendChild(wrapper);

    let bezelButtons = null;
    if (this.actionable && window.BezelButtons) {
      bezelButtons = new window.BezelButtons({
        udid: this.udid,
        layout: this.layout,
        onPress: this.onPress,
      });
      bezelButtons.mount(wrapper);
    }

    return { wrapper, screenArea, canvas, frameImg, bezelButtons };
  };

  /** Logical screen size in chrome-pixel space. Falls back to a
   *  sane iPhone default when no layout is available so input math
   *  doesn't divide by zero. */
  DeviceFrame.prototype.screenSize = function () {
    if (this.layout && this.layout.screen) {
      return { w: this.layout.screen.width, h: this.layout.screen.height };
    }
    return { w: 440, h: 956 };
  };

  window.DeviceFrame = DeviceFrame;
})();
