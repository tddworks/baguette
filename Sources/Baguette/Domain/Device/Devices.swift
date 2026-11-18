import Foundation
import Mockable

/// Every device baguette can see right now — the list the CLI, the server
/// and the page read. One per device family (`CoreSimulators`, …), and
/// `CombinedDevices` merges them into the one the App holds.
@Mockable
protocol Devices: AnyObject, Sendable {
    /// A fresh snapshot per read.
    var all: [any Device] { get }

    /// The device `id` names, or nil when none does. Throws when the
    /// answer would be a guess (`CombinedDevices`: two sources claim it).
    func find(id: DeviceID) throws -> (any Device)?
}

extension Devices {
    /// The role playing `ability` on the device `id` names — or a refusal
    /// naming the id, the ability the device lacks, or, for an ability that
    /// acts on a running device, that it isn't ready. The App's one way in.
    func require<Role>(_ ability: Ability<Role>, of id: DeviceID) throws -> Role {
        try device(id).require(ability)
    }

    /// The device `id` names, or a refusal naming the id.
    func device(_ id: DeviceID) throws -> any Device {
        guard let device = try find(id: id) else { throw DeviceError.unknown(id: id) }
        return device
    }

    /// The list a client sees: each device's identity, kind, state and
    /// abilities, so the page shows only the cards a device has.
    var listJSON: String {
        let dict: [String: Any] = ["devices": all.map(\.listing)]
        let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

extension Devices {
    /// The physical devices ready to drive, in the shape the serve page's
    /// device list reads (`/devices.json`): identity, model, and what each
    /// can do.
    var connectedJSON: String {
        let connected = all
            .filter { $0.kind.reality == .physical && $0.state == .ready }
            .map { device -> [String: Any] in
                ["udid": device.id.raw, "name": device.name,
                 "model": device.kind.model, "capabilities": device.abilities.names]
            }
        let data = try! JSONSerialization.data(
            withJSONObject: ["connected": connected], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

extension Device {
    /// The role playing `ability` on this device: refused when the device
    /// never registered it, or when it acts on a running device and this
    /// one isn't ready.
    func require<Role>(_ ability: Ability<Role>) throws -> Role {
        try require(ability, from: abilities)
    }

    /// The role playing `ability` in `abilities` this device built, refused
    /// as `require(_:)` refuses.
    func require<Role>(_ ability: Ability<Role>, from abilities: Abilities) throws -> Role {
        let role = try abilities.require(ability)
        guard !ability.needsReady || state.canAcceptInput else {
            throw DeviceError.notReady(device: name, state: state)
        }
        return role
    }
}

/// The sources, merged. One id names one device: when two sources claim
/// it, asking for it is a refusal, never a pick. Listing shows both, so
/// the clash is visible.
final class CombinedDevices: Devices {
    private let sources: [any Devices]

    init(_ sources: [any Devices]) {
        self.sources = sources
    }

    var all: [any Device] { sources.flatMap(\.all) }

    func find(id: DeviceID) throws -> (any Device)? {
        let found = try sources.compactMap { try $0.find(id: id) }
        guard found.count <= 1 else { throw DeviceError.claimedTwice(id: id) }
        return found.first
    }
}

extension Device {
    /// One `baguette list` line, its first four fields in a simulator
    /// line's order so callers that grep them read a phone the same way.
    var json: String {
        let fields: [(String, String)] = [
            ("udid", id.raw), ("name", name), ("state", state.wireName), ("runtime", ""),
            ("reality", kind.reality.rawValue), ("model", kind.model),
        ]
        return "{" + fields.map { "\"\($0.0)\":\"\(Self.escape($0.1))\"" }.joined(separator: ",") + "}"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

extension Device {
    /// The device as a client reads it: id, name, kind, state and what it
    /// can do.
    var listing: [String: Any] {
        var result: [String: Any] = [
            "id": id.raw,
            "name": name,
            "kind": [
                "platform": kind.platform.rawValue,
                "reality": kind.reality.rawValue,
                "model": kind.model,
            ],
            "state": state.wireName,
            "abilities": abilities.names,
        ]
        if case let .unavailable(reason) = state { result["reason"] = reason }
        return result
    }
}

private extension DeviceState {
    var wireName: String {
        switch self {
        case .off:         return "off"
        case .starting:    return "starting"
        case .ready:       return "ready"
        case .unavailable: return "unavailable"
        }
    }
}

extension Devices {
    /// The physical devices among these — what the device page lists as
    /// connected. A view of the same list, never a second one.
    var physical: any Devices { PhysicalDevices(of: self) }
}

private final class PhysicalDevices: Devices, @unchecked Sendable {
    private let base: any Devices

    init(of base: any Devices) { self.base = base }

    var all: [any Device] { base.all.filter { $0.kind.reality == .physical } }

    func find(id: DeviceID) throws -> (any Device)? {
        try base.find(id: id).flatMap { $0.kind.reality == .physical ? $0 : nil }
    }
}
