// MacDisplay — one of this Mac's displays: framed in a Mac frame that fits
// it, or none; shared to a viewer's own screen when its page is a share's.
import { deviceOf, describeListed } from '../../device/device.js';
import { pickedChrome } from '../../device/picked-chrome.js';
import { MacShare } from './share.js';

export function macDisplay(listing, { id, wire, storage, address }) {
  const share = MacShare.fromAddress(address);
  return deviceOf(listing, {
    id,
    family: 'mac',
    frame: { definition: pickedChrome(id, { wire, storage }), offersChromePicker: true, offersMacFrames: true },
    badge: true,
    describe: () => describeListed(id, listing, wire),
    ...(share ? { share } : {}),
  });
}
