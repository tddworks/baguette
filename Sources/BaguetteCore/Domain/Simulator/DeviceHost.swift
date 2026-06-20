import Foundation
import Mockable

/// Lookup port for live `SimDevice` `NSObject`s by UDID. The
/// Infrastructure adapters (`IndigoHIDInput`,
/// `AXPTranslatorAccessibility`, `SimDeviceLogStream`) depend on
/// this rather than the concrete `CoreSimulators` aggregate, so
/// tests can substitute `MockDeviceHost` to drive the
/// error-handling branches that don't require a real CoreSimulator
/// daemon (host gone, unknown UDID, device-not-booted).
///
/// Returns `NSObject?` rather than a typed `SimDevice` because
/// CoreSimulator's `SimDevice` is a private ObjC class whose
/// concrete type we can't import statically — adapters interact
/// with it via the runtime (`value(forKey:)`, `responds(to:)`,
/// `class_getMethodImplementation`). Tests can fake it with an
/// `NSObject` subclass that overrides KVC for the keys they need.
@Mockable
protocol DeviceHost: AnyObject, Sendable {
    /// Look up the underlying `SimDevice` for a UDID. Returns
    /// `nil` when the device set has no matching device (or the
    /// CoreSimulator framework didn't load).
    func resolveDevice(udid: String) -> NSObject?
}
