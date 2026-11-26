import ArgumentParser
import BaguetteDevice
import BaguetteDeviceFamilies
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

    /// Make the display (`make`), say which it made (`say`), and hold it
    /// (`holdOn`); with none made, say why and exit failed.
    func hold(make: (String, SharedScreenShape, UInt32) -> VirtualDisplayAnnouncement,
              say: (String) -> Void, holdOn: () -> Void) throws {
        let announcement = make(name, shape, serial)
        say(announcement.line)
        guard case .ready = announcement else { throw ExitCode.failure }
        holdOn()
    }
}
