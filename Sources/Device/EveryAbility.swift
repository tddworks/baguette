import Foundation

// The abilities a device can register, one key per role. A new ability is
// one key here plus a registration in each family that can perform it.
//
// A key that drives the running screen — what it shows, what touches it,
// how it is turned or shaken, what is on it — needs a ready device; the
// rest let their role's own adapter answer, as each did before.

public extension Ability where Role == any Power {
    static var power: Self { .init(name: "power") }
}

public extension Ability where Role == any Screen {
    /// The device's main screen.
    static var screen: Self { .init(name: "screen", needsReady: true) }
}

public extension Ability where Role == any Displays {
    /// Every display plane: the phone, a foldable's panels, CarPlay.
    static var displays: Self { .init(name: "displays", needsReady: true) }
}

public extension Ability where Role == any Hinge {
    static var hinge: Self { .init(name: "hinge", needsReady: true) }
}

public extension Ability where Role == any ExternalDisplays {
    static var externalDisplays: Self { .init(name: "externalDisplays") }
}

public extension Ability where Role == any Accessibility {
    static var accessibility: Self { .init(name: "accessibility", needsReady: true) }
}

public extension Ability where Role == any LogStream {
    static var logs: Self { .init(name: "logs") }
}

public extension Ability where Role == any Orientation {
    static var orientation: Self { .init(name: "orientation", needsReady: true) }
}

public extension Ability where Role == any StatusBar {
    static var statusBar: Self { .init(name: "statusBar") }
}

public extension Ability where Role == any Interface {
    static var interface: Self { .init(name: "interface") }
}

public extension Ability where Role == any Location {
    static var location: Self { .init(name: "location") }
}

public extension Ability where Role == any Motion {
    static var motion: Self { .init(name: "motion") }
}

public extension Ability where Role == any Network {
    static var network: Self { .init(name: "network") }
}

public extension Ability where Role == any InputSurface {
    /// The input surface Device Hub can take over — a simulator's alone.
    static var inputSurface: Self { .init(name: "inputSurface", needsReady: true) }
}

public extension Ability where Role == any Pasteboard {
    static var pasteboard: Self { .init(name: "pasteboard") }
}

public extension Ability where Role == any Apps {
    static var apps: Self { .init(name: "apps") }
}

public extension Ability where Role == any Defaults {
    static var defaults: Self { .init(name: "defaults") }
}

public extension Ability where Role == any PhotoLibrary {
    static var photos: Self { .init(name: "photos") }
}

public extension Ability where Role == any Shake {
    static var shake: Self { .init(name: "shake", needsReady: true) }
}

public extension Ability where Role == any WatchPairing {
    static var watchPairing: Self { .init(name: "watchPairing") }
}
