// DeviceFilter — the device list's selection as one value, in the words of a
// device's kind: its platform (iOS, Android), whether it is real or virtual
// (a simulator, an emulator), its OS, and a search. No DOM, no globals:
// device records as `/devices.json` lists them in, plain arrays out.
class DeviceFilter {
  /**
   * @param {object} criteria
   * @param {'all'|string} criteria.platform  a kind's platform ("iOS", "android")
   * @param {'all'|'real'|'virtual'} criteria.reality
   * @param {'all'|'latest'|string} criteria.os  "latest", or one OS by name
   * @param {string} criteria.search
   */
  constructor({ platform, reality, os, search }) {
    this.platform = platform || 'all';
    this.reality = reality || 'all';
    this.os = os || 'all';
    this.search = search || '';
  }

  static version(os) {
    const match = String(os || '').match(/(\d+(?:\.\d+)*)/);
    if (!match) return [0];
    return match[1].split('.').map((n) => Number(n) || 0);
  }

  static compareVersions(a, b) {
    const av = DeviceFilter.version(a);
    const bv = DeviceFilter.version(b);
    const length = Math.max(av.length, bv.length);
    for (let i = 0; i < length; i++) {
      const diff = (av[i] || 0) - (bv[i] || 0);
      if (diff) return diff;
    }
    return 0;
  }

  /** Every OS the devices name, by system ("iOS", "watchOS"), newest first. */
  static osNames(devices) {
    const system = (os) => os.replace(/\s.*$/, '');
    return Array.from(new Set(devices.map((d) => d.os).filter(Boolean)))
      .sort((a, b) => system(a).localeCompare(system(b)) || DeviceFilter.compareVersions(b, a));
  }

  /** A device's kind for "latest": its platform, real or virtual. */
  static kindOf(device) {
    return `${device.platform}/${device.reality === 'physical' ? 'real' : 'virtual'}`;
  }

  /** The newest OS of each kind of device. */
  static newest(devices) {
    const newest = new Map();
    for (const device of devices) {
      if (!device.os) continue;
      const kind = DeviceFilter.kindOf(device);
      const current = newest.get(kind);
      if (!current || DeviceFilter.compareVersions(device.os, current) > 0) newest.set(kind, device.os);
    }
    return newest;
  }

  /** Runs this filter over a device list, finding each kind's newest OS once. */
  apply(devices) {
    const newest = DeviceFilter.newest(devices);
    return devices.filter((device) => this.matches(device, newest));
  }

  /** @param {Map<string, string>} newest  each kind's newest OS — see `newest` */
  matches(device, newest = new Map()) {
    return this._matchesPlatform(device)
      && this._matchesReality(device)
      && this._matchesOS(device, newest)
      && this._matchesSearch(device);
  }

  _matchesPlatform(device) {
    return this.platform === 'all' || device.platform === this.platform;
  }

  _matchesReality(device) {
    if (this.reality === 'real') return device.reality === 'physical';
    if (this.reality === 'virtual') return device.reality !== 'physical';
    return true;
  }

  _matchesOS(device, newest) {
    if (this.os === 'all') return true;
    if (this.os === 'latest') return !device.os || device.os === newest.get(DeviceFilter.kindOf(device));
    return device.os === this.os;
  }

  _matchesSearch(device) {
    const term = this.search.trim().toLowerCase();
    if (!term) return true;
    return `${device.name} ${device.model} ${device.os || ''} ${device.id}`
        .toLowerCase().includes(term);
  }
}

export { DeviceFilter };
