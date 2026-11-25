import Testing
@testable import BaguetteDevice

/// How many moves a dragged finger reports: as often as a real finger
/// (120 Hz) and never more than a few points apart, so UIKit's
/// interactive transitions track the drag (#158).
@Suite("FingerPace")
struct FingerPaceTests {

    @Test func `should report a long drag in moves no more than ten points apart`() {
        let moves = FingerPace.moves(from: Point(x: 201, y: 150), to: Point(x: 201, y: 650), duration: 0.1)

        #expect(moves == 50)
    }

    @Test func `should report a slow drag as often as a real finger does`() {
        let moves = FingerPace.moves(from: Point(x: 0, y: 0), to: Point(x: 0, y: 40), duration: 0.5)

        #expect(moves == 60)
    }

    @Test func `should still move a finger once when the drag goes nowhere in no time`() {
        let moves = FingerPace.moves(from: Point(x: 5, y: 5), to: Point(x: 5, y: 5), duration: 0)

        #expect(moves == 1)
    }
}
