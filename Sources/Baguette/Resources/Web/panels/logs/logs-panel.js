// The logs panel: the device's unified log, live, from info up — its view is
// `LogPanel` (internal/log-view.js; the old sidebar page shares it).
import { LogPanel } from './internal/log-view.js';

/** The panel over `View` — its real view below, a stand-in in tests. */
export function logsPanelWith(View) {
  return {
    name: 'logs', needs: 'logs', slot: 'Logs', attribute: 'logs',
    cluster: 'inspect', label: 'Logs',
    mount(host, { device }) {
      return new View(host, { udid: device.id, level: 'info' });
    },
  };
}

export const logsPanel = logsPanelWith(LogPanel);
