// Baguette SDK — the entry point.
//
//   const sim = await Baguette.use({ host, udid, send });
//   sim.mount(container);
//
// Public surface (everything else under `Baguette._*` is internal):
//   Baguette.version  — semver string
//   Baguette.use      — bootstrap a Simulator
//
// `host` is the baguette server origin (e.g. `location.origin`).
// `udid` is the simulator's UDID. `send` is the upstream sink — a
// `(payload)=>void` function the page wires to its WebSocket. The
// SDK never opens its own socket; the consumer owns transport
// lifecycle so it can multiplex frames + control on one WS.
//
// SDK design rules (enforced by code review, not the compiler):
//   • Only `transport.js` knows the wire format.
//   • Each part is its own class in `parts/<name>.js`.
//   • Gesture interpreters live in `gestures/<name>.js` and call
//     domain methods on parts — never wire envelopes.
//   • Adding a new part doesn't change the public API.
(function (root) {
  'use strict';

  root.Baguette = root.Baguette || {};
  root.Baguette.version = '0.1.0';

  /**
   * Fetch the simulator's definition and return a ready Simulator.
   * @param {object} opts
   * @param {string} opts.host  baguette server origin
   * @param {string} opts.udid
   * @param {(payload:object)=>void} opts.send  wire sink
   * @param {(msg:string, isErr?:boolean)=>void} [opts.log]
   * @returns {Promise<Simulator>}
   */
  root.Baguette.use = async function use({ host, udid, send, log, getOrientation }) {
    if (!udid) throw new Error('Baguette.use: udid is required');
    if (typeof send !== 'function') throw new Error('Baguette.use: send must be a function');

    const base = host || location.origin;
    const url  = `${base}/simulators/${encodeURIComponent(udid)}/definition.json`;
    const res  = await fetch(url, { cache: 'no-cache' });
    if (!res.ok) {
      throw new Error(`Baguette.use: definition fetch failed (${res.status})`);
    }
    const def = await res.json();

    const T = root.Baguette._Transport;
    const transport = new T({ send, log });
    return new root.Baguette._Simulator(def, transport, { getOrientation, log });
  };
})(window);
