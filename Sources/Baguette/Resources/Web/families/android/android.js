// Android — an emulator or a device on adb: framed in the chrome its user
// picks, described by its own listing, badged with what it can do.
import { deviceOf, describeListed } from '../../device/device.js';
import { pickedChrome } from '../../device/picked-chrome.js';
import { chromePicker } from '../../device/chrome-picker.js';

export function android(listing, { id, devices, storage, address, reload }) {
  // An emulator boots; a device on adb is on when it's listed: the server says which.
  const boots = !!(listing && Array.isArray(listing.abilities) && listing.abilities.includes('power'));
  return deviceOf(listing, {
    id,
    family: 'android',
    frame: { definition: pickedChrome(id, { devices, storage, address }), chromePicker: chromePicker(id, { devices, storage, reload }) },
    badge: true,
    ...(boots ? { power: { boot: () => devices.boot(id) } } : {}),
    describe: () => describeListed(id, listing, devices),
  });
}
