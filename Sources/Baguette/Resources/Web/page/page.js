// The page sim.html loads: a device's own page at /devices/<id>, otherwise
// the devices list with its inline stream view and the families' offers.
import { devicePage } from './device-page.js';
import { devicesList } from './devices-list.js';
import { devicesStream } from './devices-stream.js';
import { shareOffers } from './devices-list-share.js';

if (!devicePage()) {
  const offers = [];
  const list = devicesList({ offers: () => offers });
  devicesStream({ reloadList: () => list.reload() });
  // A family's offers can arrive after the list did.
  shareOffers().then((found) => {
    if (!found.length) return;
    offers.push(...found);
    list.reload();
  });
}
