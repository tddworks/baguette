// The camera panel: the Mac's webcam into the device's camera (camera-view.js).
// Its control shows when the camera is streaming, open or not.
import { mountView } from '../sheet-view.js';

export const cameraPanel = {
  name: 'camera', needs: 'camera', slot: 'Camera', attribute: 'camera',
  cluster: 'simulate', label: 'Camera',
  mount(host, { device, control }) {
    return mountView('CameraPanel', host, device, {
      prepare: (view) => {
        view.onPhaseChange = (phase) => { if (control) control.classList.toggle('streaming', phase === 'streaming'); };
      },
    });
  },
};
