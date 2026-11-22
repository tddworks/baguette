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

    /// Make `display` main in `configuration`; exit failed when it never takes.
    func makeMain(with configuration: any DisplayConfiguration,
                  pause: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws {
        guard MainDisplayMove(configuration: configuration, pause: pause).makeMain(display) else { throw ExitCode.failure }
    }
}
