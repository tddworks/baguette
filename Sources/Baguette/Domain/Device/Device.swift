import Foundation
import Mockable

/// One thing baguette can drive — a simulator, a phone on a cable, a phone
/// running the companion app, an emulator. Who it is, whether it can be
/// driven now, and what it can do.
///
/// It has no method per ability: what it can do is the `AbilityTable` its
/// family built, and asking for anything else is refused by name.
@Mockable
protocol Device: Sendable {
    var id: DeviceID { get }
    var name: String { get }
    var kind: DeviceKind { get }
    var state: DeviceState { get }
    var abilities: AbilityTable { get }
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
    enum Platform: String, Sendable { case iOS, android }
    /// Apple's `devicectl` column: whether the device is a real one.
    enum Reality: String, Sendable { case simulated, physical, emulated }

    let platform: Platform
    let reality: Reality
    /// The key bezels and 3D models are found by: a device-type name
    /// ("iPhone 17 Pro"), a product type ("iPhone19,7"), an AVD's model.
    let model: String
}
