import Foundation

// The abilities a device can register, one key per role. A new ability is
// one key here plus a registration in each family that can perform it.

extension Ability where Role == any Location {
    static var location: Self { .init(name: "location") }
}

extension Ability where Role == any Shake {
    static var shake: Self { .init(name: "shake") }
}
