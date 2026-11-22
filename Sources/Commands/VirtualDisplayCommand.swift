import ArgumentParser
import BaguetteDevice
import Foundation

/// `baguette virtual-display --name … --width … --height … --serial …` —
/// not for people: `serve --share-mac` runs one per display it shares a viewer
/// through. It makes one display of `width` × `height` points at 2×, says
/// `ready <id> <uuid>` (or `failed <why>`) on stdout, and keeps the display
/// until it is ended or the server that started it is gone. A process of its
/// own because macOS lets a process choose the mode of only the first virtual
/// display it makes (docs/features/mac-screen/design.md).
struct VirtualDisplayCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "virtual-display",
        abstract: "Hold one virtual display for a screen share (run by serve)",
        shouldDisplay: false
    )

    @Option(name: .long) var name: String
    @Option(name: .long) var width: Int
    @Option(name: .long) var height: Int
    @Option(name: .long) var serial: UInt32

    var shape: SharedScreenShape {
        SharedScreenShape(points: Size(width: Double(width), height: Double(height)))
    }

    func run() throws {
        let announcement = VirtualDisplayHold.make(named: name, shape: shape, serial: serial)
        VirtualDisplayLife.say(announcement.line)
        guard case .ready = announcement else { throw ExitCode.failure }
        VirtualDisplayLife.holdUntilOrphaned()
    }
}
