// The location panel: a map that sets or moves the device's location
// (location-view.js). Each opening re-measures the map, which may have been
// laid out at zero size while the sheet was faded out.
import { mountView } from '../sheet-view.js';
import { LocationPanel } from './internal/location-view.js';

/** The panel over `View` — its real view below, a stand-in in tests. */
export function locationPanelWith(View) {
  return {
    name: 'location', needs: 'location', slot: 'Location', attribute: 'location',
    cluster: 'simulate', label: 'Location',
    mount: (host, { device }) => mountView(View, host, device, { refreshes: true }),
  };
}

export const locationPanel = locationPanelWith(LocationPanel);

