// The one place the page builds a device's resource URLs: every device —
// a simulator, a phone on a cable — answers under `/devices/:udid/…`.
// `/devices/:udid` still serves this page, but its resources come from
// the devices tree.
const BaguetteTarget = {
  /** The resource root every device's routes answer under. */
  base: 'devices',
  /** '/devices/<udid><rest>'. */
  path(udid, rest) {
    return '/devices/' + encodeURIComponent(udid) + (rest || '');
  },
};

export { BaguetteTarget };
