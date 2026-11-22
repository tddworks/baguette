// The one place the page builds a device's resource URLs: every device —
// a simulator, a phone on a cable — answers under `/devices/:udid/…`.
// `/devices/:udid` still serves this page, but its resources come from
// the devices tree. Loaded before every other script.
(function () {
  'use strict';

  window.BaguetteTarget = {
    /** The resource root every device's routes answer under. */
    base: 'devices',
    /**
     * Whether the page drives a physical phone is the device's kind, not
     * the URL: the device page reads it from /devices/<udid>/device.json.
     */
    isDevice: false,
    /** '/devices/<udid><rest>'. */
    path(udid, rest) {
      return '/devices/' + encodeURIComponent(udid) + (rest || '');
    },
  };
})();
