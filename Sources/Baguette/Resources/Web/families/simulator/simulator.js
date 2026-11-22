// Simulator — an Apple simulator: framed by its own bezel, described as the
// server lists its simulators.
import { deviceOf } from '../../device/device.js';
import { bootThroughServer } from '../../device/power.js';
import { toPortrait } from './portrait.js';

/** `com.apple.CoreSimulator.SimRuntime.iOS-26-4` → `iOS 26.4`. */
function formatRuntime(raw) {
  return String(raw || '')
    .replace('com.apple.CoreSimulator.SimRuntime.', '')
    .replace(/^iOS-/, 'iOS ')
    .replace(/-/g, '.');
}

export function simulator(listing, { id, wire }) {
  return deviceOf(listing, {
    id,
    family: 'simulator',
    frame: { definition: undefined },
    power: bootThroughServer(id, wire),
    /** It turns: input drawn turned goes back to portrait before it's sent. */
    orientation: { toPortrait },
    /** Its name, runtime and state, from the server's list of simulators. */
    async describe() {
      try {
        const json = await wire.simulators();
        const all = (json.running || []).concat(json.available || []);
        const hit = all.find((d) => (d.id || d.udid) === id);
        if (hit) {
          return {
            name: hit.name || 'Simulator',
            runtime: hit.displayRuntime || formatRuntime(hit.runtime || hit.os || ''),
            state: hit.state || '',
          };
        }
      } catch { /* not listed */ }
      return { name: 'Simulator', runtime: '', state: '' };
    },
  });
}
