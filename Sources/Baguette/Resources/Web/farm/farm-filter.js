// FarmFilter — owns the filter state and the predicate that maps it
// onto a device list. Pulled out of FarmApp so the predicate is
// trivially unit-testable and so the rail can rebind events without
// the orchestrator caring.
//
//   const filter = new FarmFilter({ runtimes });
//   filter.toggle('platforms', 'iphone');
//   filter.search = 'pro max';
//   const visible = filter.apply(allDevices);   // → filtered subset
//
// Default policy: every facet starts inclusive (all known options
// checked). Discovered runtimes seed the runtime set; new runtimes
// added later are merged in via `seedRuntimes()`.
class FarmFilter {
  constructor(opts) {
    this.platforms = new Set(['iphone', 'ipad', 'watch', 'tv']);
    this.runtimes  = new Set(opts?.runtimes || []);
    this.states    = new Set(['live', 'boot', 'idle', 'off', 'error']);
    this.search    = '';
  }

  seedRuntimes(runtimes) {
    runtimes.forEach((r) => this.runtimes.add(r));
  }

  toggle(facet, value) {
    const set = this[facet];
    if (!set) return;
    set.has(value) ? set.delete(value) : set.add(value);
  }

  apply(devices) {
    const q = this.search.trim().toLowerCase();
    return devices.filter((d) =>
      this.platforms.has(d.platform) &&
      this.runtimes.has(d.runtime) &&
      this.states.has(d.uiState) &&
      (q === '' ||
        (d.name + ' ' + d.udid + ' ' + d.runtime + ' ' + d.platform)
            .toLowerCase().includes(q)));
  }

  // Counts per facet — used by the rail to render the "(N)" badges.
  counts(devices) {
    const platform = {};
    const state    = {};
    devices.forEach((d) => {
      platform[d.platform] = (platform[d.platform] || 0) + 1;
      state[d.uiState]     = (state[d.uiState]     || 0) + 1;
    });
    return { platform, state };
  }
}

export { FarmFilter };
