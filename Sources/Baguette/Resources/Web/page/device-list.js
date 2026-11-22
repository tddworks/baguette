// The devices list's own additions to the list (sim-list.js draws the list):
// sharing this Mac to the device the page is on, when the server shares it.
import { isDevicesList, sharingOn, mountShareCard, pageBrowser } from '../families/mac/share-card.js';

async function offerSharing() {
  if (!isDevicesList(location.pathname)) return;
  const browser = pageBrowser();
  if (!(await sharingOn(browser))) return;
  const host = document.createElement('section');
  host.id = 'macShareHost';
  host.style.cssText = 'max-width:440px;margin:16px auto;padding:0 16px;box-sizing:border-box';
  const card = document.createElement('div');
  host.appendChild(card);
  document.body.prepend(host);
  mountShareCard(card, browser, (url) => location.assign(url));
}

void offerSharing();
