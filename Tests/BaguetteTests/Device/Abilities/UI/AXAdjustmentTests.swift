import Foundation
import Testing
@testable import BaguetteDevice

/// Stepping a slider or stepper through accessibility — its increment and
/// decrement actions, the way VoiceOver's swipe up and down does — never by
/// dragging. Each step is sent once and read back; a step the element
/// refuses, or one whose outcome can't be read, ends the run unretried.
@Suite("AXAdjustment")
struct AXAdjustmentTests {
    /// A control holding a number that each step moves by one.
    final class Stepper: @unchecked Sendable {
        var value: Int
        var usable = true
        var refuseAfter: Int?
        private(set) var steps: [Bool] = []
        init(value: Int) { self.value = value }

        var element: AXAdjustment.Element {
            AXAdjustment.Element(
                value: { "\(self.value)" },
                usable: { self.usable },
                step: { increment in
                    self.steps.append(increment)
                    if let limit = self.refuseAfter, self.steps.count > limit { return false }
                    self.value += increment ? 1 : -1
                    return true
                })
        }
    }

    private static let soon = Date().addingTimeInterval(60)

    @Test func `should step an element as many times as asked and report the value it ends on`() {
        let stepper = Stepper(value: 5)

        let result = AXAdjustment.run(steps: 3, on: stepper.element, deadline: Self.soon, settle: { _ in })

        #expect(result == AXAdjustment(requested: 3, completed: 3, valueBefore: "5", valueAfter: "8", failure: nil))
        #expect(stepper.steps == [true, true, true])
    }

    @Test func `should step down for a negative count`() {
        let stepper = Stepper(value: 5)

        let result = AXAdjustment.run(steps: -2, on: stepper.element, deadline: Self.soon, settle: { _ in })

        #expect(result.completed == 2)
        #expect(result.valueAfter == "3")
        #expect(stepper.steps == [false, false])
    }

    @Test func `should stop at the first step the element refuses, without retrying it`() {
        let stepper = Stepper(value: 0)
        stepper.refuseAfter = 1

        let result = AXAdjustment.run(steps: 4, on: stepper.element, deadline: Self.soon, settle: { _ in })

        #expect(result.completed == 1)
        #expect(result.valueAfter == "1")
        #expect(result.failure != nil)
        #expect(stepper.steps.count == 2)
    }

    @Test func `should stop when the element becomes disabled or hidden partway`() {
        let stepper = Stepper(value: 0)
        let element = stepper.element
        let watching = AXAdjustment.Element(
            value: element.value, usable: { stepper.steps.count < 2 && stepper.usable }, step: element.step)

        let result = AXAdjustment.run(steps: 5, on: watching, deadline: Self.soon, settle: { _ in })

        #expect(result.completed == 2)
        #expect(result.failure != nil)
    }

    @Test func `should refuse a count of zero, which moves nothing`() {
        let stepper = Stepper(value: 4)

        let result = AXAdjustment.run(steps: 0, on: stepper.element, deadline: Self.soon, settle: { _ in })

        #expect(result.failure != nil)
        #expect(stepper.steps.isEmpty)
    }

    @Test func `should refuse to step an element that offers no step that way`() {
        let node = AXNode(role: "AXSlider", frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 1, height: 1)),
                          adjustmentActions: ["AXIncrement"])

        #expect(AXAdjustment.refusal(stepping: node, by: -1) != nil)
        #expect(AXAdjustment.refusal(stepping: node, by: 2) == nil)
    }

    /// A step that changes text size re-renders the page; for a moment the
    /// element has no value to read. That is "not yet", not "moved".
    @Test func `should keep waiting while a stepped element has no value to read`() {
        #expect(!AXAdjustment.settled(after: "83%", now: nil))
        #expect(!AXAdjustment.settled(after: "83%", now: "83%"))
        #expect(AXAdjustment.settled(after: "83%", now: "67%"))
    }

    @Test func `should take no step once its deadline has passed`() {
        let stepper = Stepper(value: 0)

        let result = AXAdjustment.run(
            steps: 3, on: stepper.element, deadline: Date().addingTimeInterval(-1), settle: { _ in })

        #expect(result.completed == 0)
        #expect(result.failure != nil)
        #expect(stepper.steps.isEmpty)
    }
}
