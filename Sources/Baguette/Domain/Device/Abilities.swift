import Foundation

/// Something a device can be told to do, named by the role that does it.
/// The `Role` type travels with the key, so `require(.location)` hands
/// back an `any Location` the compiler checked.
struct Ability<Role>: Sendable {
    let name: String
    /// Whether the role acts on a running device. `Devices.require`
    /// refuses such an ability while the device isn't ready.
    let needsReady: Bool

    init(name: String, needsReady: Bool = false) {
        self.name = name
        self.needsReady = needsReady
    }
}

/// What one device can do: each registered ability mapped to the role
/// that plays it. Anything else is refused by name — never a fallback,
/// never a role that pretends.
///
/// A device family builds its abilities once, where the device is built;
/// that is the only place deciding what the family can do.
struct Abilities: Sendable {
    private let device: String
    private var entries: [(name: String, make: @Sendable () -> Any)] = []

    /// - Parameter device: the device's name, so a refusal can say whose it is.
    init(device: String) {
        self.device = device
    }

    /// Register the role that plays `ability`. `make` runs on every
    /// `require`, so a role that is a fresh handle per call stays one.
    /// Registering an ability again replaces it in place.
    mutating func register<Role>(_ ability: Ability<Role>, _ make: @escaping @Sendable () -> Role) {
        let entry = (name: ability.name, make: { make() as Any } as @Sendable () -> Any)
        if let index = entries.firstIndex(where: { $0.name == ability.name }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    /// The role registered for `ability`, or a refusal naming the ability
    /// and the device.
    func require<Role>(_ ability: Ability<Role>) throws -> Role {
        guard let entry = entries.first(where: { $0.name == ability.name }),
              let role = entry.make() as? Role
        else { throw DeviceError.unable(ability: ability.name, device: device) }
        return role
    }

    /// A refusal naming what this device can't do.
    func refusal(_ what: String) -> DeviceError {
        .unable(ability: what, device: device)
    }

    /// The registered abilities, in the order they were registered.
    var names: [String] { entries.map(\.name) }
}
