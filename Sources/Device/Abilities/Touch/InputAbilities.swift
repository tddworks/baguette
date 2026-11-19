import Foundation

public extension Ability where Role == any Touch {
    static var touch: Self { .init(name: "touch", needsReady: true) }
}

public extension Ability where Role == any Press {
    static var press: Self { .init(name: "press", needsReady: true) }
}

public extension Ability where Role == any Key {
    static var key: Self { .init(name: "key", needsReady: true) }
}

public extension Ability where Role == any Scroll {
    static var scroll: Self { .init(name: "scroll", needsReady: true) }
}

public extension Device {
    /// Its own screen's input: its input abilities, each made once, so a
    /// finger lifts where it went down. Refused when the device has nothing
    /// to touch or isn't running.
    func input() throws -> Abilities {
        let screen = abilities.resolvingInputOnce()
        _ = try require(.touch, from: screen)
        return screen
    }
}

public extension Abilities {
    /// One screen's input: its touch, and the buttons, keys and wheel its
    /// device has. One it lacks is absent — asking for it is refused by
    /// name, never answered by a role that pretends.
    static func input(
        of device: String, touch: any Touch,
        press: (any Press)? = nil, key: (any Key)? = nil, scroll: (any Scroll)? = nil
    ) -> Abilities {
        var abilities = Abilities(device: device)
        abilities.register(.touch) { touch }
        if let press { abilities.register(.press) { press } }
        if let key { abilities.register(.key) { key } }
        if let scroll { abilities.register(.scroll) { scroll } }
        return abilities
    }

    /// These abilities with their input made once and kept: a gesture session
    /// asks for a role per gesture, and a finger that went down on one
    /// touch has to move and lift on that same one.
    func resolvingInputOnce() -> Abilities {
        var abilities = self
        abilities.keep(.touch)
        abilities.keep(.press)
        abilities.keep(.key)
        abilities.keep(.scroll)
        return abilities
    }

    private mutating func keep<Role: Sendable>(_ ability: Ability<Role>) {
        guard let role = try? require(ability) else { return }
        register(ability) { role }
    }
}
