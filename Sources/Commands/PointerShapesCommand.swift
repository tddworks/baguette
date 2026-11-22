import ArgumentParser
import BaguetteDevice
import Foundation

/// `baguette pointer-shapes` — not for people: `serve --share-mac` runs one
/// while anyone views a Mac display. It says the Mac's pointer shape, one
/// `shape …` line per change (`PointerShape`), until its server is gone. A
/// process of its own because only one whose run loop runs follows the shape
/// (docs/features/mac-screen/design.md#the-pointer).
struct PointerShapesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pointer-shapes",
        abstract: "Say the Mac's pointer shape as it changes (run by serve)",
        shouldDisplay: false
    )

    func run() throws {
        PointerShapeWatch.sayChanges { line in
            print(line)
            fflush(stdout)
        }
    }
}
