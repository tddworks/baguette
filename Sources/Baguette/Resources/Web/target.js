// The one place the page knows WHAT it is driving. `/simulators/:udid`
// and `/devices/:udid` serve the same sim.html; every module builds
// its resource URLs through this seam so a physical device reuses the
// whole page with the base path switched. Loaded before every other
// script.
(function () {
  'use strict';

  const parts = location.pathname.split('/').filter(Boolean);
  const base = parts[0] === 'devices' ? 'devices' : 'simulators';

  window.BaguetteTarget = {
    /** 'simulators' | 'devices' — the resource root this page drives. */
    base,
    /** True on /devices/:udid — a physical phone behind the mirror. */
    isDevice: base === 'devices',
    /** '/devices/<udid><rest>' or '/simulators/<udid><rest>'. */
    path(udid, rest) {
      return '/' + base + '/' + encodeURIComponent(udid) + (rest || '');
    },
  };
})();
