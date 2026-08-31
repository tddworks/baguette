// DeviceFilter — the simulator list's family/runtime/search selection as
// one value, matching the UI's own mental model: the user sets a filter,
// then applies it to the device list. No DOM, no globals: plain device
// records in, plain arrays out.
(function (root) {
  'use strict';

  class DeviceFilter {
    /**
     * @param {object} criteria
     * @param {'iphones'|'ipads'|'all'} criteria.family
     * @param {'latest'|'all'|string} criteria.runtime
     * @param {string} criteria.search
     */
    constructor({ family, runtime, search }) {
      this.family = family;
      this.runtime = runtime;
      this.search = search;
    }

    static runtimeVersion(runtime) {
      const match = String(runtime || '').match(/(\d+(?:\.\d+)*)/);
      if (!match) return [0];
      return match[1].split('.').map((n) => Number(n) || 0);
    }

    static compareVersions(a, b) {
      const av = DeviceFilter.runtimeVersion(a);
      const bv = DeviceFilter.runtimeVersion(b);
      const length = Math.max(av.length, bv.length);
      for (let i = 0; i < length; i++) {
        const diff = (av[i] || 0) - (bv[i] || 0);
        if (diff) return diff;
      }
      return 0;
    }

    static latestRuntime(devices) {
      return devices.reduce(
          (latest, device) => (
            DeviceFilter.compareVersions(device.runtime, latest) > 0 ? device.runtime : latest
          ),
          ''
      );
    }

    /** Runs this filter over a device list, computing "latest" once. */
    apply(devices) {
      const latest = DeviceFilter.latestRuntime(devices);
      return devices.filter((device) => this.matches(device, latest));
    }

    /** @param {string} latest  the group's highest runtime — see `latestRuntime` */
    matches(device, latest) {
      return this._matchesFamily(device)
        && this._matchesRuntime(device, latest)
        && this._matchesSearch(device);
    }

    _matchesFamily(device) {
      if (this.family === 'iphones') return /^iphone\b/i.test(device.name);
      if (this.family === 'ipads') return /^ipad\b/i.test(device.name);
      return true;
    }

    _matchesRuntime(device, latest) {
      if (this.runtime === 'latest') return !latest || device.runtime === latest;
      if (this.runtime === 'all') return true;
      return device.runtime === this.runtime;
    }

    _matchesSearch(device) {
      const term = (this.search || '').trim().toLowerCase();
      if (!term) return true;
      return `${device.name} ${device.state} ${device.runtime} ${device.id}`
          .toLowerCase().includes(term);
    }
  }

  root.Baguette = root.Baguette || {};
  root.Baguette._DeviceFilter = DeviceFilter;
})(window);
