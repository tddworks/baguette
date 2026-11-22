// Simulator — an Apple simulator: framed by its own bezel, described as the
// server lists its simulators.
import { deviceOf } from '../../device/device.js';
import { toPortrait } from './internal/portrait.js';
import { companionScreens } from './internal/companions.js';

/** `com.apple.CoreSimulator.SimRuntime.iOS-26-4` → `iOS 26.4`. */
function formatRuntime(raw) {
  return String(raw || '')
    .replace('com.apple.CoreSimulator.SimRuntime.', '')
    .replace(/^iOS-/, 'iOS ')
    .replace(/-/g, '.');
}

export function simulator(listing, { id, devices }) {
  return deviceOf(listing, {
    id,
    family: 'simulator',
    frame: { definition: undefined },
    power: { boot: () => devices.boot(id) },
    /** It turns: a quarter clockwise each step of its cycle, on the server;
     *  input drawn turned goes back to portrait before it's sent. */
    orientation: {
      cycle: ['portrait', 'landscape-left', 'portrait-upside-down', 'landscape-right'],
      turn: (value) => devices.turn(id, value),
      toPortrait,
    },
    /** Its other screens: the CarPlay display and the paired watch, beside it. */
    companions: { mount: (page) => companionScreens(page) },
    /** Its name, runtime and state, from the server's list of simulators. */
    async describe() {
      try {
        const json = await devices.simulators();
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
