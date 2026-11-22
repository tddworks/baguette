// The network panel: latency, bandwidth, loss, offline (network-view.js). Its
// control carries an armed dot — kept honest from the page's start, opened or
// not: a forgotten throttle presents as "the app is slow", days later.
import { mountView } from '../sheet-view.js';
import { NetworkPanel } from './internal/network-view.js';

/** The control says whether a throttle is on — in words too, for a screen reader. */
function markArmed(control, armed, summary) {
  if (!control) return;
  control.classList.toggle('conditioning', !!armed);
  const label = armed ? `Network conditioning on${summary ? ` — ${summary}` : ''}` : 'Network conditioning off';
  control.setAttribute('aria-label', label);
  control.setAttribute('title', label);
}

/** The panel over `View` — its real view below, a stand-in in tests. */
export function networkPanelWith(View) {
  return {
    name: 'network', needs: 'network', slot: 'Network', attribute: 'network',
    cluster: 'simulate', label: 'Network',
    mount(host, { device, control }) {
      return mountView(View, host, device, {
        refreshes: true,
        prepare: (view) => { view.onArmedChange = (form) => markArmed(control, form.isConditioning, form.describe()); },
      });
    },
    /** Poll the device's conditioning: the CLI or the route can arm one this page never saw. */
    watch({ device, control }) {
      const poll = async () => {
        try {
          const res = await fetch(`/devices/${encodeURIComponent(device.id)}/network`);
          if (res.ok) {
            const state = await res.json();
            markArmed(control, state.active, state.summary);
          }
        } catch { /* leave the mark as it was */ }
      };
      poll();
      window.setInterval(poll, 5000);
    },
  };
}

export const networkPanel = networkPanelWith(NetworkPanel);

