// The device page's panels — the one list of them. A new panel is one import
// and one entry here; the sheet rule is `Panels`'.
import { Panels } from '../device/panels.js';
import { logsPanel } from '../panels/logs/logs-panel.js';
import { cameraPanel } from '../panels/camera/camera-panel.js';
import { statusBarPanel } from '../panels/status-bar/status-bar-panel.js';
import { networkPanel } from '../panels/network/network-panel.js';
import { notifyPanel } from '../panels/notify/notify-panel.js';
import { defaultsPanel } from '../panels/defaults/defaults-panel.js';
import { locationPanel } from '../panels/location/location-panel.js';

export const pagePanels = [logsPanel, cameraPanel, statusBarPanel, networkPanel, notifyPanel, defaultsPanel, locationPanel];

/** The page's panels, on `page` (which finds its elements by id). */
export function panelsOn(page) {
  return new Panels(page, pagePanels);
}

// The old scripts reach it here until they're modules too (design §6).
if (typeof window !== 'undefined') {
  window.Baguette = window.Baguette || {};
  window.Baguette._PagePanels = { on: panelsOn };
}
