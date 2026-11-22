import ArgumentParser
import Foundation

// The commands `serve --share-mac` runs, on this Mac. Integration-only: each
// hands its tested decision (`hold`, `makeMain`) the real system calls, and
// `pointer-shapes` is the system call alone.

extension VirtualDisplayCommand {
    func run() throws {
        try hold(make: VirtualDisplayHold.make, say: ServeChild.say, holdOn: { ServeChild.holdUntilOrphaned() })
    }
}

extension MainDisplayCommand {
    func run() throws {
        try makeMain(with: CoreGraphicsDisplayConfiguration())
    }
}

extension PointerShapesCommand {
    func run() throws {
        PointerShapeWatch.sayChanges(ServeChild.say)
    }
}
