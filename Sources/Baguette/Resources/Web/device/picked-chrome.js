// A chrome the user picked for a device that has none of its own (a phone on
// the cable, an Android device, a Mac display): remembered per device, it
// rides `?chrome=` into the device's definition route.

/** The device's definition route, with its picked chrome when there is one. */
export function pickedChrome(id, { wire, storage }) {
  let pick = null;
  try { pick = storage.getItem('baguette.twin.chrome.' + id); } catch { /* none remembered */ }
  return wire.path(id, '/definition.json') + (pick ? '?chrome=' + encodeURIComponent(pick) : '');
}
