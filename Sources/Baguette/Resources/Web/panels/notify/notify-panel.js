// The notify panel: deliver a remote notification to an app (notify-view.js).
import { mountView } from '../sheet-view.js';

export const notifyPanel = {
  name: 'notify', needs: 'notify', slot: 'Notify', attribute: 'notify',
  mount: (host, { device }) => mountView('NotifyPanel', host, device),
};
