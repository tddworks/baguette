// A chrome the user picked for a device that has none of its own (a phone on
// the cable, an Android device, a Mac display): it rides `?chrome=` into the
// device's definition route. The pick is remembered per device; when the
// browser won't store it, the page's own address carries it through the reload.

// `none` in the address is a pick too — no chrome — so a browser that can't
// forget an earlier pick still shows the device unframed.
const NONE = 'none';

/** The device's definition route, with its picked chrome when there is one. */
export function pickedChrome(id, { devices, storage, address = '' }) {
  let pick = new URLSearchParams(address).get('chrome');
  if (pick === NONE) return devices.definitionURL(id, null);
  if (!pick) {
    try { pick = storage.getItem('baguette.twin.chrome.' + id); } catch { /* none remembered */ }
  }
  return devices.definitionURL(id, pick);
}

/** How a pick rides `?chrome=` through the reload: its name, or `none` for no frame. */
export function chromeInAddress(pick) {
  return pick || NONE;
}
