// The status bar panel: the device's status bar overrides (status-bar-view.js).
import { mountView } from '../sheet-view.js';
import { StatusBarPanel } from './internal/status-bar-view.js';

/** The panel over `View` — its real view below, a stand-in in tests. */
export function statusBarPanelWith(View) {
  return {
    name: 'statusBar', needs: 'statusBar', slot: 'StatusBar', attribute: 'statusbar',
    cluster: 'simulate', label: 'Status bar',
    mount: (host, { device }) => mountView(View, host, device),
  };
}

export const statusBarPanel = statusBarPanelWith(StatusBarPanel);

