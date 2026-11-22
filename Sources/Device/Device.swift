import Foundation
import Mockable

/// One thing baguette can drive — a simulator, a phone on a cable, a phone
/// running the companion app, an emulator. Who it is, whether it can be
/// driven now, and what it can do.
///
/// It has no method per ability: what it can do is the `Abilities` its
/// family built, and asking for anything else is refused by name.
@Mockable
public protocol Device: Sendable {
    var id: DeviceID { get }
    var name: String { get }
    var kind: DeviceKind { get }
    var state: DeviceState { get }
    var abilities: Abilities { get }
}

/// A device's identity across every family: a simulator's or iPhone's
/// UDID, an adb serial.
public struct DeviceID: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let raw: String

    public init(_ raw: String) { self.raw = raw }
    public init(stringLiteral raw: String) { self.raw = raw }

    public var description: String { raw }
}

/// What a device is: its platform, whether it is real, and its model.
public struct DeviceKind: Equatable, Sendable {
    public enum Platform: String, Sendable { case iOS, watchOS, tvOS, visionOS, android, macOS }
    /// Apple's `devicectl` column: whether the device is a real one.
    public enum Reality: String, Sendable { case simulated, physical, emulated }

    public let platform: Platform
    public let reality: Reality
    /// What the device is, by the name bezels are found under: a device-type
    /// or marketing name ("iPhone 18 Pro Max"), an AVD's model.
    public let model: String
    /// The hardware identifier ("iPhone19,7") 3D models are matched by,
    /// when the device reports one.
    public let hardware: String?
    /// The system it runs, by name and version ("iOS 26.4", "Android 15"),
    /// when its family can say.
    public let os: String?

    public init(platform: Platform, reality: Reality, model: String, hardware: String? = nil, os: String? = nil) {
        self.platform = platform
        self.reality = reality
        self.model = model
        self.hardware = hardware
        self.os = os
    }
}
