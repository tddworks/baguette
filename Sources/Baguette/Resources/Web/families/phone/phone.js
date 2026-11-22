// Phone — an iPhone or iPad on the cable: framed in the chrome its user
// picks, described by its own listing, badged with what it can do.
import { deviceOf, describeListed } from '../../device/device.js';
import { pickedChrome } from '../../device/picked-chrome.js';
import { chromePicker } from '../../device/chrome-picker.js';

export function phone(listing, { id, devices, storage, address, reload }) {
  return deviceOf(listing, {
    id,
    family: 'phone',
    frame: { definition: pickedChrome(id, { devices, storage, address }), chromePicker: chromePicker(id, { devices, storage, reload }) },
    badge: true,
    describe: () => describeListed(id, listing, devices),
  });
}
