import Foundation

// The abilities a device can register, one key per role. A new ability is
// one key here plus a registration in each family that can perform it.

extension Ability where Role == any Lifecycle {
    static var lifecycle: Self { .init(name: "lifecycle") }
}

extension Ability where Role == any Screen {
    /// The device's main screen.
    static var screen: Self { .init(name: "screen") }
}

extension Ability where Role == any Input {
    /// Gestures to the device's main screen.
    static var input: Self { .init(name: "input") }
}

extension Ability where Role == any Displays {
    /// Every display plane: the phone, a foldable's panels, CarPlay.
    static var displays: Self { .init(name: "displays") }
}

extension Ability where Role == any Hinge {
    static var hinge: Self { .init(name: "hinge") }
}

extension Ability where Role == any ExternalDisplays {
    static var externalDisplays: Self { .init(name: "externalDisplays") }
}

extension Ability where Role == any Accessibility {
    static var accessibility: Self { .init(name: "accessibility") }
}

extension Ability where Role == any LogStream {
    static var logs: Self { .init(name: "logs") }
}

extension Ability where Role == any Orientation {
    static var orientation: Self { .init(name: "orientation") }
}

extension Ability where Role == any StatusBar {
    static var statusBar: Self { .init(name: "statusBar") }
}

extension Ability where Role == any Interface {
    static var interface: Self { .init(name: "interface") }
}

extension Ability where Role == any Location {
    static var location: Self { .init(name: "location") }
}

extension Ability where Role == any Motion {
    static var motion: Self { .init(name: "motion") }
}

extension Ability where Role == any Network {
    static var network: Self { .init(name: "network") }
}

extension Ability where Role == any Pasteboard {
    static var pasteboard: Self { .init(name: "pasteboard") }
}

extension Ability where Role == any Apps {
    static var apps: Self { .init(name: "apps") }
}

extension Ability where Role == any Defaults {
    static var defaults: Self { .init(name: "defaults") }
}

extension Ability where Role == any PhotoLibrary {
    static var photos: Self { .init(name: "photos") }
}

extension Ability where Role == any Shake {
    static var shake: Self { .init(name: "shake") }
}

extension Ability where Role == any WatchPairing {
    static var watchPairing: Self { .init(name: "watchPairing") }
}
