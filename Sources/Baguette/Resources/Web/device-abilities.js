// DeviceAbilities — which of the page's controls a device can use, from
// the abilities the server lists for it (`abilities` in
// /devices/<id>/device.json). The server decides what a device can do;
// this only maps each control to the ability it drives, so the page shows
// only what the device has — the same page for a simulator and a phone.
(function (root) {
  'use strict';

  /** The ability each toolbar control drives; absent → it needs none. */
  const NEEDS = {
    nativeRotate: 'orientation',
    nativeHome: 'press',
    nativeAppSwitcher: 'press',
    nativeShake: 'shake',
    nativeStatusBarToggle: 'statusBar',
    nativeLocationToggle: 'location',
    nativeNotifyToggle: 'notify',
    nativeCameraToggle: 'camera',
    nativeAxToggle: 'accessibility',
    nativeLogsToggle: 'logs',
    nativeDefaultsToggle: 'defaults',
  };

  function list(abilities) {
    return Array.isArray(abilities) ? abilities : [];
  }

  const DeviceAbilities = {
    /** Every control that needs an ability. */
    controls() {
      return Object.keys(NEEDS);
    },

    /** @returns {boolean} whether `abilities` includes `ability`. */
    has(abilities, ability) {
      return list(abilities).includes(ability);
    },

    /** @returns {boolean} whether the control shows for these abilities. */
    shows(controlId, abilities) {
      const needs = NEEDS[controlId];
      return !needs || list(abilities).includes(needs);
    },

    /** @returns {string[]} the controls among `controlIds` to hide. */
    hidden(controlIds, abilities) {
      return controlIds.filter((id) => !DeviceAbilities.shows(id, abilities));
    },
  };

  root.Baguette = root.Baguette || {};
  root.Baguette._DeviceAbilities = DeviceAbilities;
})(window);
