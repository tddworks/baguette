import Foundation

/// What a device has yet to do, in the order it was sent — except that a
/// pointer move still waiting is replaced by a newer one: only where the
/// pointer is now matters, so the pointer never trails behind the hand.
/// Anything that isn't a move (a finger landing or lifting, a tap, a key, a
/// scroll) keeps its place and is never dropped, and a move is never moved
/// past one. Apple's Screen Sharing keeps its pointer this way.
public struct PendingGestures<Work> {
    private var entries: [(work: Work, motion: Bool)] = []

    public init() {}

    public mutating func add(_ work: Work, motion: Bool) {
        if motion, let last = entries.last, last.motion {
            entries[entries.count - 1] = (work, true)
        } else {
            entries.append((work, motion))
        }
    }

    /// The next to do, taken off the front; nil when nothing waits.
    public mutating func next() -> Work? {
        entries.isEmpty ? nil : entries.removeFirst().work
    }
}
