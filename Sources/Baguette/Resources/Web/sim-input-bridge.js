// SimInputBridge — translator + transport factory bridging SimInput's
// asc-cli plugin dialect to Baguette's GestureRegistry wire format.
//
// Two clients consume this:
//   • sim-stream.js     (single-device page)
//   • farm/farm-tile.js (device farm — focused tile)
//
// Wire-dialect deltas (kept verbatim from sim-stream.js):
//   • SimInput payloads carry `kind:"tap"`, `kind:"touchDown"` with
//     `fingers[]`. Baguette wants `type:"tap"`, `type:"touch1-down"`,
//     `startX/endX/x1/x2` instead of `x1/x2`.
//   • SimInput emits normalized [0,1] coords + width/height device
//     points. Baguette's `IndigoHIDInput.sendMouse` expects coords in
//     *device-point space* and re-normalizes internally — the bridge
//     multiplies by width/height before sending.
//   • `key`/`type` aren't on Baguette's host-HID path yet; they're
//     dropped with a log on the standalone serve route.
(function () {
  'use strict';

  function toBaguetteWire(p, log) {
    log = log || (() => {});
    const w = p.width, h = p.height;
    const base = { width: w, height: h };
    const px = (x) => x * w;
    const py = (y) => y * h;
    switch (p.kind) {
      case 'tap':
        return { type: 'tap', x: px(p.x), y: py(p.y),
                 duration: p.duration ?? 0.05, ...base };
      case 'swipe':
        return {
          type: 'swipe',
          startX: px(p.x1), startY: py(p.y1),
          endX:   px(p.x2), endY:   py(p.y2),
          duration: p.duration ?? 0.25,
          ...base
        };
      case 'touchDown':
      case 'touchMove':
      case 'touchUp':
        return phasedTouch(p, base, px, py);
      case 'scroll':
        return { type: 'scroll', deltaX: p.deltaX, deltaY: p.deltaY };
      case 'button':
        return { type: 'button', button: p.button };
      case 'key':
      case 'type':
        log(`${p.kind}: not on Baguette's host-HID path`, true);
        return null;
      default:
        return null;
    }
  }

  // touchDown/Move/Up + N fingers → touch1-* / touch2-*. Other counts
  // are dropped (Baguette only supports 1 or 2 simultaneous fingers).
  function phasedTouch(p, base, px, py) {
    const phase = p.kind.replace('touch', '').toLowerCase();
    const fingers = p.fingers || [];
    if (fingers.length === 1) {
      return {
        type: `touch1-${phase}`,
        x: px(fingers[0].x), y: py(fingers[0].y),
        ...base
      };
    }
    if (fingers.length === 2) {
      return {
        type: `touch2-${phase}`,
        x1: px(fingers[0].x), y1: py(fingers[0].y),
        x2: px(fingers[1].x), y2: py(fingers[1].y),
        ...base
      };
    }
    return null;
  }

  // Adapter for SimInput's `transport` option: translate then send via
  // a StreamSession's send(). Drops payloads that have no Baguette
  // equivalent so SimInput's own promise chain still resolves.
  function makeTransport(session, log) {
    return (payload) => {
      const wire = toBaguetteWire(payload, log);
      if (wire && session && typeof session.send === 'function') {
        session.send(wire);
      }
    };
  }

  window.SimInputBridge = { toBaguetteWire, makeTransport };
})();
