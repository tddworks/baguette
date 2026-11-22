// The defaults panel: an app's typed UserDefaults (defaults-view.js). Each
// opening re-reads the device: the app may have rewritten its own while shut.
import { mountView } from '../sheet-view.js';
import { DefaultsPanel } from './internal/defaults-view.js';

/** The panel over `View` — its real view below, a stand-in in tests. */
export function defaultsPanelWith(View) {
  return {
    name: 'defaults', needs: 'defaults', slot: 'Defaults', attribute: 'defaults',
    cluster: 'inspect', label: 'Defaults',
    mount: (host, { device }) => mountView(View, host, device, { refreshes: true }),
  };
}

export const defaultsPanel = defaultsPanelWith(DefaultsPanel);

