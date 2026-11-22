// The logs panel: the device's unified log, live, from info up — its view is
// `LogPanel` (log-view.js, a classic script the old sidebar page shares).

export const logsPanel = {
  name: 'logs',
  needs: 'logs',
  slot: 'Logs',
  attribute: 'logs',
  cluster: 'inspect',
  label: 'Logs',
  mount(host, { device }) {
    return new window.LogPanel(host, { udid: device.id, level: 'info' });
  },
};
