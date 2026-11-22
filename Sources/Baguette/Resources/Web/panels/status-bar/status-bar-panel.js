// The status bar panel: the device's status bar overrides (status-bar-view.js).
import { mountView } from '../sheet-view.js';

export const statusBarPanel = {
  name: 'statusBar', needs: 'statusBar', slot: 'StatusBar', attribute: 'statusbar',
  mount: (host, { device }) => mountView('StatusBarPanel', host, device),
};
