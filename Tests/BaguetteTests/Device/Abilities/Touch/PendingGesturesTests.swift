import Testing
@testable import BaguetteDevice

/// What a device has yet to do: in the order it was sent, except that a
/// pointer move still waiting is replaced by a newer one — only where the
/// pointer is now matters, so the pointer never trails behind the hand.
@Suite("PendingGestures")
struct PendingGesturesTests {
    /// Each entry: the work, and the kind of pointer move it is (`true` for a
    /// hover, as most of these are); `false`, not a move.
    func pending(_ entries: [(String, Bool)]) -> PendingGestures<String> {
        entries.reduce(into: PendingGestures<String>()) { $0.add($1.0, move: $1.1 ? "hover" : nil) }
    }

    func drained(_ pending: PendingGestures<String>) -> [String] {
        var pending = pending
        var out: [String] = []
        while let next = pending.next() { out.append(next) }
        return out
    }

    @Test func `should keep only the newest of pointer moves waiting together`() {
        #expect(drained(pending([("move1", true), ("move2", true), ("move3", true)])) == ["move3"])
    }

    @Test func `should never drop or reorder a click among pointer moves`() {
        let waiting = pending([("move1", true), ("down", false), ("move2", true), ("move3", true), ("up", false)])
        #expect(drained(waiting) == ["move1", "down", "move3", "up"])
    }

    @Test func `should keep a waiting move when a move of another kind comes after it`() {
        var waiting = PendingGestures<String>()
        waiting.add("scroll1", move: "touch2-move")
        waiting.add("hover1", move: "hover")
        waiting.add("hover2", move: "hover")
        #expect(drained(waiting) == ["scroll1", "hover2"])
    }

    @Test func `should keep everything that isn't a pointer move, in order`() {
        #expect(drained(pending([("tap", false), ("key", false), ("tap", false)])) == ["tap", "key", "tap"])
    }

    @Test func `should say how many gestures wait, a replaced move counted once`() {
        #expect(pending([("move1", true), ("move2", true), ("tap", false)]).count == 2)
    }

    @Test func `should hand on what waits in the order it came`() {
        var waiting = pending([("down", false), ("move1", true)])
        #expect(waiting.next() == "down")
        waiting.add("move2", move: "hover")
        #expect(waiting.next() == "move2")
        #expect(waiting.next() == nil)
    }
}
