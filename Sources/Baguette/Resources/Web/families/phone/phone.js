// Phone — an iPhone or iPad on the cable: framed in the chrome its user
// picks, described by its own listing, badged with what it can do.
import { deviceOf, describeListed } from '../../device/device.js';
import { pickedChrome } from '../../device/picked-chrome.js';
import { chromePicker } from '../../device/chrome-picker.js';

export function phone(listing, { id, wire, storage, address, reload }) {
  return deviceOf(listing, {
    id,
    family: 'phone',
    frame: { definition: pickedChrome(id, { wire, storage, address }), chromePicker: chromePicker(id, { wire, storage, reload }) },
    badge: true,
    describe: () => describeListed(id, listing, wire),
  });
}
