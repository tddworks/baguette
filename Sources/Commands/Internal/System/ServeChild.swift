import BaguetteDevice
import Darwin
import Foundation

/// A process `serve` started (`virtual-display`, `pointer-shapes`): its lines
/// to the server, on stdout, and its life — as long as the server's. SIGTERM
/// (the share ended) ends it by default; so does its server going away, which
/// leaves it orphaned to launchd. Integration-only.
enum ServeChild {
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
