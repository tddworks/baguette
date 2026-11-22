// The notify panel: deliver a remote notification to an app (notify-view.js).
import { mountView } from '../sheet-view.js';
import { NotifyPanel } from './internal/notify-view.js';

/** The panel over `View` — its real view below, a stand-in in tests. */
export function notifyPanelWith(View) {
  return {
    name: 'notify', needs: 'notify', slot: 'Notify', attribute: 'notify',
    cluster: 'simulate', label: 'Notification',
    mount: (host, { device }) => mountView(View, host, device),
  };
}

export const notifyPanel = notifyPanelWith(NotifyPanel);

