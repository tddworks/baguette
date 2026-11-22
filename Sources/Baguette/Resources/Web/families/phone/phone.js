// Phone — an iPhone or iPad on the cable: framed in the chrome its user
// picks, described by its own listing, badged with what it can do.
import { deviceOf, describeListed } from '../../device/device.js';
import { pickedChrome } from '../../device/picked-chrome.js';

export function phone(listing, { id, wire, storage }) {
  return deviceOf(listing, {
    id,
    family: 'phone',
    frame: { definition: pickedChrome(id, { wire, storage }), offersChromePicker: true, offersMacFrames: false },
    badge: true,
    describe: () => describeListed(id, listing, wire),
  });
}
