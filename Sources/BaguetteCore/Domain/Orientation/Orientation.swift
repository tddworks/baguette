import Foundation
import Mockable

/// The booted simulator's interface-orientation surface. Setting the
/// orientation fires a GSEvent through the simulator's
/// `PurpleWorkspacePort` so the iOS guest sees
/// `UIDeviceOrientationDidChange` and rotates the UIKit world.
///
/// Write-only on purpose: GraphicsServices doesn't vend a "what's
/// my current orientation" probe to outside processes — the host
/// drives state, the guest reads the latest event.
@Mockable
protocol Orientation: Sendable {
    /// Apply `orientation` to the booted simulator. Returns `false`
    /// when the GSEvent could not be delivered (port not vended, or
    /// `mach_msg_send` rejected the message). The guest may further
    /// reject the rotation if the foreground app declares
    /// `UISupportedInterfaceOrientations` excluding it; that's a
    /// guest-side decision and shows up as the visual frame staying
    /// put. No way to detect that from here.
    func set(_ orientation: DeviceOrientation) -> Bool
}
