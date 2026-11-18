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

extension Device {
    /// The role playing `ability` on this device: refused when the device
    /// never registered it, or when it acts on a running device and this
    /// one isn't ready.
    func require<Role>(_ ability: Ability<Role>) throws -> Role {
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

private extension Device {
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
