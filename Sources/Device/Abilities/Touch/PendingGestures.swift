import Foundation

/// What a device has yet to do, in the order it was sent — except that a
/// pointer move still waiting is replaced by a newer move of its kind (a
/// hover by a hover, a drag by a drag): only where the pointer is now
/// matters, so the pointer never trails behind the hand.
/// Anything that isn't a move (a finger landing or lifting, a tap, a key, a
/// scroll) keeps its place and is never dropped, and a move is never moved
/// past one. Apple's Screen Sharing keeps its pointer this way.
public struct PendingGestures<Work> {
    private var entries: [(work: Work, move: String?)] = []

    public init() {}

    /// `move`: the kind of pointer move `work` is (its wire type); nil when it isn't one.
    public mutating func add(_ work: Work, move: String?) {
        if let move, let last = entries.last, last.move == move {
            entries[entries.count - 1] = (work, move)
        } else {
            entries.append((work, move))
        }
    }

    /// How many gestures wait.
    public var count: Int { entries.count }

    /// The next to do, taken off the front; nil when nothing waits.
    public mutating func next() -> Work? {
        entries.isEmpty ? nil : entries.removeFirst().work
    }
}
