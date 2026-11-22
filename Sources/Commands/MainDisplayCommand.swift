import ArgumentParser
import BaguetteDevice
import Foundation

/// `baguette main-display --display <id>` — not for people: `serve --share-mac`
/// runs it to make a shared display main, or to give main back. Exits 0 once
/// the display is main. A process of its own because a process that changes
/// the arrangement stops seeing displays added after it
/// (docs/features/mac-screen/design.md).
struct MainDisplayCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "main-display",
        abstract: "Make one display main for a screen share (run by serve)",
        shouldDisplay: false
    )

    @Option(name: .long) var display: UInt32
    /// Keep nothing beside the Dock's edge of the display (a share made main).
    @Flag(name: .customLong("free-dock")) var freeDock = false

    /// Make `display` main in `configuration` — freeing the Dock's edge
    /// (`dockOrientation`: where macOS says the Dock is) when asked; exit
    /// failed when it never takes.
    func makeMain(with configuration: any DisplayConfiguration, dockOrientation: () -> String? = { nil },
                  pause: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws {
        let edge = freeDock ? DockEdge(orientation: dockOrientation()) : nil
        guard MainDisplayMove(configuration: configuration, pause: pause).makeMain(display, freeing: edge) else {
            throw ExitCode.failure
        }
    }
}
