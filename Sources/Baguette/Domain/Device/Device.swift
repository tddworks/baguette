import Foundation
import Mockable

/// One thing baguette can drive — a simulator, a phone on a cable, a phone
/// running the companion app, an emulator. Who it is, whether it can be
/// driven now, and what it can do.
///
/// It has no method per ability: what it can do is the `Abilities` its
/// family built, and asking for anything else is refused by name.
@Mockable
protocol Device: Sendable {
    var id: DeviceID { get }
    var name: String { get }
    var kind: DeviceKind { get }
    var state: DeviceState { get }
    var abilities: Abilities { get }
}

/// A device's identity across every family: a simulator's or iPhone's
/// UDID, an adb serial.
struct DeviceID: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    let raw: String

    init(_ raw: String) { self.raw = raw }
    init(stringLiteral raw: String) { self.raw = raw }

    var description: String { raw }
}

/// What a device is: its platform, whether it is real, and its model.
struct DeviceKind: Equatable, Sendable {
    enum Platform: String, Sendable { case iOS, watchOS, tvOS, visionOS, android }
    /// Apple's `devicectl` column: whether the device is a real one.
    enum Reality: String, Sendable { case simulated, physical, emulated }

    let platform: Platform
    let reality: Reality
    /// What the device is, by the name bezels are found under: a device-type
    /// or marketing name ("iPhone 18 Pro Max"), an AVD's model.
    let model: String
    /// The hardware identifier ("iPhone19,7") 3D models are matched by,
    /// when the device reports one.
    let hardware: String?

    init(platform: Platform, reality: Reality, model: String, hardware: String? = nil) {
        self.platform = platform
        self.reality = reality
        self.model = model
        self.hardware = hardware
    }
}
