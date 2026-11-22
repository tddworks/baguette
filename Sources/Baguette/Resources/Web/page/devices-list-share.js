// The devices list's offers from the Mac family: when the server shares this
// Mac, the display it can make for this screen is offered as one more device
// in the list (families/mac/share-card.js `shareOffer`), with Share… as its
// action. The list renders an offer as it renders any device, and runs the
// offer's own action — it knows nothing about Macs.
import { isDevicesList, sharingOn, shareOffer, pageBrowser } from '../families/mac/share-card.js';

/** The offers for this page: the Mac's share when the server shares it, else none. */
export async function shareOffers() {
  if (!isDevicesList(location.pathname)) return [];
  if (!(await sharingOn(pageBrowser()))) return [];
  return [shareOffer()];
}
