import BaguetteDevice
import Foundation

/// Whether SimulatorKit should call `updateIOPorts` before reading
/// framebuffer descriptors. Creating ports is only necessary when the
/// device exposes none — refreshing against an already-connected
/// TVOut/CarPlay resets guest display services and wedges the external
/// surface (proven in the sim_carplay spike).
enum FramebufferRefresh {
    static func shouldUpdate(hasFramebuffers: Bool) -> Bool {
        !hasFramebuffers
    }
}
