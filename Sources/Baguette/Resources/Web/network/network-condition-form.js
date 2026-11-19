// NetworkConditionForm — what the network card's controls currently say,
// as one value that knows how to post itself and how to describe itself.
//
// The route takes **exactly one** source of truth per request: a preset
// name, explicit numbers, or offline. So the decision of which one is being
// asked for belongs somewhere it can be asserted, not scattered through
// event handlers that each guess. No DOM, no globals: plain fields in,
// a plain body out.
//
// A chosen preset posts its *name*, never its numbers. Network Link
// Conditioner's figures live in `NetworkProfile` on the Swift side, and a
// second copy here would drift.
(function (root) {
  'use strict';

  function num(value) {
    const n = Number(value);
    return Number.isFinite(n) ? n : null;
  }

  class NetworkConditionForm {
    /**
     * @param {object} fields
     * @param {string}  [fields.profile]        a preset name, e.g. '3g'
     * @param {number}  [fields.latencyMs]      round-trip milliseconds
     * @param {number}  [fields.bandwidthKbps]  downlink kbps; 0/null = unmetered
     * @param {number}  [fields.lossPercent]    0…100
     * @param {boolean} [fields.offline]
     */
    constructor({ profile, latencyMs, bandwidthKbps, lossPercent, offline } = {}) {
      this.profile = profile || null;
      this.latencyMs = num(latencyMs);
      this.bandwidthKbps = num(bandwidthKbps);
      this.lossPercent = num(lossPercent);
      this.offline = !!offline;
    }

    /**
     * Reads back what `GET /devices/:udid/network` reports.
     *
     * `profile` is carried across deliberately. The card posts a preset's
     * name and the device answers with numbers *plus* the preset they came
     * from; dropping that name is what made a pressed pill deselect itself
     * the moment the response landed.
     */
    static fromState(state) {
      if (!state || !state.active) return new NetworkConditionForm({});
      return new NetworkConditionForm({
        profile: state.profile,
        latencyMs: state.latencyMs,
        bandwidthKbps: state.bandwidthKbps,
        lossPercent: state.lossPercent,
        offline: state.offline,
      });
    }

    /**
     * Which control the card should show as chosen: a preset's name,
     * `'offline'`, `'custom'`, or `'off'`.
     *
     * The three number fields only make sense under Custom. A preset
     * already states every number it conditions, so showing editable
     * fields beside a lit preset invites the exact combination the route
     * refuses — and reads as though they could be layered.
     */
    get mode() {
      if (this.offline) return 'offline';
      if (this.profile) return this.profile;
      return this.isConditioning ? 'custom' : 'off';
    }

    /**
     * The request body, or `null` when nothing is being asked for — the
     * route refuses such a request, so the card should not make it.
     */
    toBody() {
      if (this.offline) return { offline: true };
      if (this.profile) return { profile: this.profile };
      const body = {};
      if (this.latencyMs > 0) body.latencyMs = this.latencyMs;
      // Absent rather than zero: a zero would have to mean either
      // "unlimited" or "nothing gets through".
      if (this.bandwidthKbps > 0) body.bandwidthKbps = this.bandwidthKbps;
      if (this.lossPercent > 0) body.lossPercent = this.lossPercent;
      return Object.keys(body).length ? body : null;
    }

    /** One short phrase for the armed badge. */
    describe() {
      if (this.offline) return 'Offline';
      if (this.profile) return this.profile;
      const parts = [];
      if (this.latencyMs > 0) parts.push(`${this.latencyMs} ms`);
      if (this.bandwidthKbps > 0) parts.push(`${this.bandwidthKbps} kbps`);
      if (this.lossPercent > 0) parts.push(`${this.lossPercent}% loss`);
      return parts.length ? parts.join(' · ') : 'Off';
    }

    /** Whether this form is asking for anything at all. */
    get isConditioning() {
      return this.toBody() !== null;
    }
  }

  root.Baguette = root.Baguette || {};
  root.Baguette._NetworkConditionForm = NetworkConditionForm;
})(window);
