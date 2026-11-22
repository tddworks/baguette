// MacDisplay — one of this Mac's displays: framed in a Mac frame that fits
// it, or none; shared to a viewer's own screen when its page is a share's.
import { deviceOf, describeListed } from '../../device/device.js';
import { pickedChrome } from '../../device/picked-chrome.js';
import { MacShare } from './share.js';
import { followShare } from './share-follow.js';
import { macPointer } from './pointer.js';
import { macFramePicker } from './frame-picker.js';

export function macDisplay(listing, { id, wire, storage, address }) {
  const shared = MacShare.fromAddress(address);
  return deviceOf(listing, {
    id,
    family: 'mac',
    frame: {
      definition: pickedChrome(id, { wire, storage }),
      offersChromePicker: true,
      picker: macFramePicker(id, { wire, storage, reload: () => MacShare.reloadKeepingShare(window.location) }),
    },
    badge: true,
    pointer: macPointer,
    describe: () => describeListed(id, listing, wire),
    ...(shared ? { share: { ...shared, follow: (browser) => followShare(shared, MacShare, browser) } } : {}),
  });
}
