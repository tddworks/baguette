// Families — the one place that reads a device's kind: each listing becomes
// the Device its family builds. A new kind of device is a new family and one
// line here; the page and the other families don't change.
import { simulator } from './simulator/simulator.js';
import { phone } from './phone/phone.js';
import { android } from './android/android.js';
import { macDisplay } from './mac/mac-display.js';

function familyOf(listing) {
  const kind = (listing && listing.kind) || null;
  if (!kind || kind.reality === 'simulated') return simulator;
  if (kind.platform === 'macOS') return macDisplay;
  if (kind.platform === 'android') return android;
  return phone;
}

export const Families = {
  /**
   * The Device `listing` names (nil: a simulator the server lists nothing
   * for). `id`: its id; `devices`: the server's devices (device/devices.js); `storage`: what
   * the page remembers; `address`: the page's query string; `reload`: how
   * the page reloads itself (a share's keeps its share).
   */
  device(listing, { id, devices, storage, address = '', reload = () => {} }) {
    return familyOf(listing)(listing, { id, devices, storage, address, reload });
  },
};

// The old scripts reach it here until they're modules too (design §6).
