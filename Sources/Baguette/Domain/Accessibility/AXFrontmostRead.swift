import Foundation

/// How a read of the frontmost app chooses between its two routes.
///
/// The host bridge names the frontmost app in milliseconds, but it is
/// not enough on its own: on iOS 26.5 it can answer empty, and a freshly
/// launched app shows it an empty tree until a guest accessibility client
/// has connected. The guest helper settles both, at about half a second a
/// run, so it runs only when the bridge could not read the app. Each read
/// asks afresh; no PID outlives its query.
///
/// The app's tree appears a moment after the helper connects, and until then a
/// read finds only the status bar. With Device Hub open that was every first read
/// after a launch (12 of 12), so the guest route gives it a moment.
enum AXFrontmostRead {
    struct Timing: Equatable, Sendable {
        /// How long an app the helper just woke gets to show its tree.
        var wake: TimeInterval = 1.5
        var poll: TimeInterval = 0.05
    }

    enum Source: Equatable, Sendable {
        case bridge
        case guest
    }

    static func read(
        bridge: () -> Int32?,
        guest: () throws -> Int32,
        tree: (Int32, Source) throws -> AXNode?,
        timing: Timing = Timing(),
        now: () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws -> AXNode? {
        if let pid = bridge(), pid > 0,
            let answer = try? tree(pid, .bridge), !answer.children.isEmpty
        {
            return answer
        }
        let pid = try guest()
        let start = now()
        var answer = try tree(pid, .guest)
        while answer?.showsOnlyTheStatusBar != false, now() - start < timing.wake {
            sleep(timing.poll)
            answer = try tree(pid, .guest)
        }
        return answer
    }
}
