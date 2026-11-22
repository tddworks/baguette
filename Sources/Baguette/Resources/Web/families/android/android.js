// Android — an emulator or a device on adb: framed in the chrome its user
// picks, described by its own listing, badged with what it can do.
import { deviceOf, describeListed } from '../../device/device.js';
import { pickedChrome } from '../../device/picked-chrome.js';

export function android(listing, { id, wire, storage }) {
  return deviceOf(listing, {
    id,
    family: 'android',
    frame: { definition: pickedChrome(id, { wire, storage }), offersChromePicker: true },
    badge: true,
    describe: () => describeListed(id, listing, wire),
  });
}
