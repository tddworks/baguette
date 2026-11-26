import BaguetteDevice
import Foundation
import Mockable

/// A device's hardware keys, pressed the way Device Hub presses them:
/// one HID key event down, held, then up, on the guest daemon's own
/// buttons service. iPhone Duo's SpringBoard takes volume, power and
/// the camera control only from there — the legacy Indigo press lands
/// on a touchscreen service and is ignored. The production impl is
/// `HIDButtonsKeys`, which runs `HIDButtons` inside the guest.
@Mockable
protocol DeviceKeys: Sendable {
    /// Press `usage` for `hold` seconds with `modifiers` held around it,
    /// down in order before it and up in reverse after — none for a
    /// hardware key. iPhone Duo takes its keyboard keys from here too.
    /// Throws when the guest tool is missing or refused.
    func press(_ usage: HIDUsage, holding modifiers: [HIDUsage], hold: TimeInterval) throws
}
