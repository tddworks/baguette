import Foundation

/// Runs an action, waits until the screen has stopped moving, and reads it.
///
/// The wait watches `glance`, the app's own tree without the hit-test sweep,
/// because it is cheap enough to poll. Only the final `read` pays for a full
/// look. So `changed` speaks for the app's own tree: a tap inside web content
/// shows up in the read, but not always in the glance.
///
/// A tree can look still before the screen is. UIKit moves a pushed page to where
/// it ends up as soon as the slide starts, and removes the old page only when it
/// ends, about half a second later. Until then both pages are in the tree, so an
/// answer could offer `Pay` beside "You're booked". And a closing sheet leaves the
/// tree empty for a moment. So those two shapes aren't settled yet.
enum AXSettle {
    struct Timing: Equatable, Sendable {
        /// How long a changed screen must hold still to count as settled.
        var quiet: TimeInterval = 0.1
        /// How long to wait for a screen that hasn't changed at all.
        var patience: TimeInterval = 1
        /// When to give up on a screen that never stops moving.
        var limit: TimeInterval = 3
        var poll: TimeInterval = 0.03
        /// How long a screen that looks mid-transition gets to finish. Something that
        /// always sits across the edge, like a carousel, looks the same and mustn't stall.
        var transition: TimeInterval = 1
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
            if !same(current, latest) {
                latest = current
                movedAt = time
            }
            let changed = !same(latest, before)
            let finishing = latest?.looksMidTransition == true && time - movedAt < timing.transition
            if changed && time - movedAt >= timing.quiet && !finishing { break }
            if !changed && time - start >= timing.patience { break }
            if time - start >= timing.limit { break }
            sleep(timing.poll)
        }
        return Outcome(changed: !same(latest, before), tree: try read())
    }

    /// A pulsing glow keeps a tree moving forever, without the screen changing.
    static func same(_ one: AXNode?, _ other: AXNode?) -> Bool {
        guard let one, let other else { return one == nil && other == nil }
        return one.looksSame(as: other)
    }
}

extension AXNode {
    /// Part of the old page still crosses the left edge, or the app shows nothing.
    fileprivate var looksMidTransition: Bool {
        let shown = preorder().dropFirst().filter { $0.hasSize && !$0.hidden }
        return shown.isEmpty
            || shown.contains { $0.frame.origin.x < -1 && $0.frame.origin.x + $0.frame.size.width > 0 }
    }
}
