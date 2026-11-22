import BaguetteDevice
import Darwin
import Foundation

/// A `virtual-display` process's life: its one line to the server, then
/// waiting — its display lives as long as it does. SIGTERM (the share ended)
/// ends it by default; so does its server going away, which leaves it
/// orphaned to launchd. Integration-only.
enum VirtualDisplayLife {
    static func say(_ line: String) {
        print(line)
        fflush(stdout)
    }

    static func holdUntilOrphaned() -> Never {
        let parent = ParentProcess(startedUnder: getppid())
        while !parent.isGone(now: getppid()) { sleep(1) }
        exit(0)
    }
}
