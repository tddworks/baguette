import Foundation

/// Waits for an app's first real screen after a launch.
///
/// The cheap `glance` is enough to wait with, once two things are handled.
/// The old screen stays up until the new app takes over, so its own movement
/// must not count as arrival: the root has to have changed too. And a freshly
/// launched app shows the bridge an empty tree until a guest accessibility
/// client connects, so it gets woken when it shows up empty, and again if it
/// stays that way. Waking any earlier only wakes the old app: a cold launch can
/// take two seconds to become frontmost. A launch that changes nothing means
/// the app was already in front.
///
/// None of this makes the first screen fast. Most of the 4 to 5 s is iOS
/// switching apps and the tree appearing after the wake. What it saves is
/// calls: one instead of the two to four reads of polling by hand.
enum AXFirstScreen {
    struct Timing: Equatable, Sendable {
        /// How long the new app must hold still to count as drawn.
        var quiet: TimeInterval = 0.1
        /// How long to wait when no new app ever appears. Switching from a
        /// running app can leave the old one frontmost for over two seconds.
        var patience: TimeInterval = 5
        /// When to stop waiting for an app that never draws.
        var limit: TimeInterval = 10
        var poll: TimeInterval = 0.03
        var wakeEvery: TimeInterval = 1.5
    }

    static func run(
        before: AXNode?,
        glance: () -> AXNode?,
        wake: () -> Void,
        read: () throws -> AXNode?,
        timing: Timing = Timing(),
        now: () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws -> AXSettle.Outcome {
        let start = now()
        var latest = before
        var movedAt = start
        var sawNewApp = false
        var wokenAt: TimeInterval?
        while true {
            let current = glance()
            let time = now()
            if current != latest {
                latest = current
                movedAt = time
            }
            let isEmpty = current?.children.isEmpty == true
            if isEmpty {
                sawNewApp = true
                if wokenAt.map({ time - $0 >= timing.wakeEvery }) ?? true {
                    wake()
                    wokenAt = now()
                }
            }
            let arrived = current != nil && !isEmpty && current?.label != before?.label
            if arrived && time - movedAt >= timing.quiet { break }
            if !arrived && !sawNewApp && time - start >= timing.patience { break }
            if time - start >= timing.limit { break }
            sleep(timing.poll)
        }
        return AXSettle.Outcome(changed: latest != before, tree: try read())
    }
}
