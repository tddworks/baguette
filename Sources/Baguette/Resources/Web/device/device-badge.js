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
      const touch = abilities.includes('touch');
      return {
        text: touch ? 'DEVICE · touch' : 'DEVICE · view-only',
        title: abilities.length
          ? 'A physical device. It can do: ' + abilities.join(', ') + '.'
          : 'A physical device that lists nothing it can do.',
      };
    },
  };

  root.Baguette = root.Baguette || {};
  root.Baguette._DeviceBadge = DeviceBadge;
})(window);
