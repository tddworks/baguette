// The location panel: a map that sets or moves the device's location
// (location-view.js). Each opening re-measures the map, which may have been
// laid out at zero size while the sheet was faded out.
import { mountView } from '../sheet-view.js';

export const locationPanel = {
  name: 'location', needs: 'location', slot: 'Location', attribute: 'location',
  cluster: 'simulate', label: 'Location',
  mount: (host, { device }) => mountView('LocationPanel', host, device, { refreshes: true }),
};
