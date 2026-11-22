// A chrome the user picked for a device that has none of its own (a phone on
// the cable, an Android device, a Mac display): it rides `?chrome=` into the
// device's definition route. The pick is remembered per device; when the
// browser won't store it, the page's own address carries it through the reload.

/** The device's definition route, with its picked chrome when there is one. */
export function pickedChrome(id, { wire, storage, address = '' }) {
  let pick = new URLSearchParams(address).get('chrome');
  if (!pick) {
    try { pick = storage.getItem('baguette.twin.chrome.' + id); } catch { /* none remembered */ }
  }
  return wire.path(id, '/definition.json') + (pick ? '?chrome=' + encodeURIComponent(pick) : '');
}
