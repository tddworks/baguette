// The defaults panel: an app's typed UserDefaults (defaults-view.js). Each
// opening re-reads the device: the app may have rewritten its own while shut.
import { mountView } from '../sheet-view.js';

export const defaultsPanel = {
  name: 'defaults', needs: 'defaults', slot: 'Defaults', attribute: 'defaults',
  cluster: 'inspect', label: 'Defaults',
  mount: (host, { device }) => mountView('DefaultsPanel', host, device, { refreshes: true }),
};
