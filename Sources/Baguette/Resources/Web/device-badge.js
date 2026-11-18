// DeviceBadge — what the device page's badge says about a physical
// device, from the abilities the server lists for it (`capabilities` in
// /devices.json). The server decides what a device can do; this only
// words it.
(function (root) {
  'use strict';

  const DeviceBadge = {
    /** @param {string[]|undefined} capabilities */
    of(capabilities) {
      const abilities = Array.isArray(capabilities) ? capabilities : [];
      const touch = abilities.includes('input');
      return {
        text: touch ? 'DEVICE · touch' : 'DEVICE · view-only',
        title: abilities.length
          ? 'A physical device. It can do: ' + abilities.join(', ') + '.'
          : 'A physical device that lists nothing it can do.',
      };
    },

    /**
     * The inspect cluster's tools a physical device's page shows: the
     * accessibility inspector when the device can do accessibility. Logs
     * and defaults are simulator-only.
     * @param {string[]|undefined} capabilities
     * @returns {string[]} toolbar button ids
     */
    inspectTools(capabilities) {
      const abilities = Array.isArray(capabilities) ? capabilities : [];
      return abilities.includes('accessibility') ? ['nativeAxToggle'] : [];
    },
  };

  root.Baguette = root.Baguette || {};
  root.Baguette._DeviceBadge = DeviceBadge;
})(window);
