import Foundation

/// Runs an action, waits until the screen has stopped moving, and reads it.
///
/// The wait watches `glance`, the app's own tree without the hit-test sweep,
/// because it is cheap enough to poll. Only the final `read` pays for a full
/// look. So `changed` speaks for the app's own tree: a tap inside web content
/// shows up in the read, but not always in the glance.
enum AXSettle {
    struct Timing: Equatable, Sendable {
        /// How long a changed screen must hold still to count as settled.
        var quiet: TimeInterval = 0.1
        /// How long to wait for a screen that hasn't changed at all.
        var patience: TimeInterval = 1
        /// When to give up on a screen that never stops moving.
        var limit: TimeInterval = 3
        var poll: TimeInterval = 0.03
    }

    struct Outcome: Equatable {
        var changed: Bool
        var tree: AXNode?
    }

    /// `nil` when `act` fails: there is no screen to wait for.
    static func run(
        act: () -> Bool,
        glance: () -> AXNode?,
        read: () throws -> AXNode?,
        timing: Timing = Timing(),
        now: () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws -> Outcome? {
        let before = glance()
        guard act() else { return nil }

        let start = now()
        var latest = before
        var movedAt = start
        while true {
            let current = glance()
            let time = now()
            if current != latest {
                latest = current
                movedAt = time
            }
            let changed = latest != before
            if changed && time - movedAt >= timing.quiet { break }
            if !changed && time - start >= timing.patience { break }
            if time - start >= timing.limit { break }
            sleep(timing.poll)
        }
        return Outcome(changed: latest != before, tree: try read())
    }
}
