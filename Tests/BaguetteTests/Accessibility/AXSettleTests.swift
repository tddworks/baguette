import Testing
import Foundation
@testable import Baguette

/// After a gesture, an agent wants the screen it caused: not one caught
/// mid-animation, and without a guessed sleep. `AXSettle` watches the app's
/// own tree until it stops moving, then takes one full read.
@Suite("AXSettle")
struct AXSettleTests {
    private static let frame = Rect(origin: Point(x: 0, y: 0), size: Size(width: 10, height: 10))
    private static let timing = AXSettle.Timing(quiet: 0.2, patience: 1, limit: 3, poll: 0.1)

    /// An app showing something: one with nothing on screen is mid-transition.
    private func screen(_ name: String) -> AXNode {
        AXNode(role: "AXApplication", label: name, frame: Self.frame, children: [AXNode(role: "AXButton", label: name, frame: Self.frame)])
    }

    /// A fake clock that a glance and a sleep both move on, so a test reads
    /// as a timeline: each glance is 0.1 s after the last.
    private final class Timeline {
        var time: TimeInterval = 0
        var glances: [AXNode?]
        var count = 0
        init(_ glances: [AXNode?]) { self.glances = glances }
        func glance() -> AXNode? {
            count += 1
            return glances.count > 1 ? glances.removeFirst() : glances.first ?? nil
        }
    }

    private func run(
        _ timeline: Timeline, act: () -> Bool = { true }, read: () throws -> AXNode? = { nil }
    ) throws -> AXSettle.Outcome? {
        try AXSettle.run(
            act: act, glance: timeline.glance, read: read, timing: Self.timing,
            now: { timeline.time }, sleep: { timeline.time += $0 })
    }

    @Test func `should report the screen changed once it has stopped moving`() throws {
        let timeline = Timeline([screen("A"), screen("B")])
        let outcome = try run(timeline, read: { screen("B") })

        #expect(outcome?.changed == true)
        #expect(outcome?.tree == screen("B"))
        #expect(timeline.time <= 0.4)
    }

    @Test func `should keep watching while the screen is still moving`() throws {
        let timeline = Timeline(["A", "B", "C", "D", "E", "E"].map(screen))
        _ = try run(timeline)

        // Quiet is only counted from the last change, at 0.4 s.
        #expect(timeline.time >= 0.6)
    }

    @Test func `should catch a change that starts late`() throws {
        let timeline = Timeline(["A", "A", "A", "A", "A", "B"].map(screen))
        let outcome = try run(timeline)

        #expect(outcome?.changed == true)
    }

    @Test func `should report nothing changed after waiting long enough`() throws {
        let timeline = Timeline([screen("A")])
        let outcome = try run(timeline, read: { screen("A") })

        #expect(outcome?.changed == false)
        #expect(outcome?.tree == screen("A"))
        #expect(timeline.time >= 1)
        #expect(timeline.time < 1.2)
    }

    @Test func `should report nothing changed when the screen moved and came back`() throws {
        let timeline = Timeline(["A", "B", "A"].map(screen))
        let outcome = try run(timeline)

        #expect(outcome?.changed == false)
    }

    @Test func `should not mistake a pulsing control for a change`() throws {
        let frame = Self.frame
        func app(_ x: Double) -> AXNode {
            AXNode(
                role: "AXApplication", label: "A", frame: frame,
                children: [AXNode(role: "AXButton", label: "Go", frame: Rect(origin: Point(x: x, y: 0), size: frame.size))])
        }
        let timeline = Timeline([app(0), app(2), app(0), app(2), app(0), app(2), app(0), app(2), app(0), app(2), app(0), app(2)])
        let outcome = try run(timeline)

        #expect(outcome?.changed == false)
        #expect(timeline.time < 1.3)
    }

    // MARK: - a page sliding away

    private static let wide = Rect(origin: Point(x: 0, y: 0), size: Size(width: 402, height: 874))

    private func app(_ name: String, sliding: Bool = false) -> AXNode {
        let x: Double = sliding ? -105 : 16
        return AXNode(
            role: "AXApplication", frame: Self.wide,
            children: [AXNode(role: "AXStaticText", label: name, frame: Rect(origin: Point(x: x, y: 114), size: Size(width: 300, height: 40)))])
    }

    private func nothing() -> AXNode { AXNode(role: "AXApplication", frame: Self.wide) }

    @Test func `should wait for the old page to finish sliding away`() throws {
        let sliding = app("Old and new", sliding: true)
        let timeline = Timeline([app("Old"), sliding, sliding, sliding, sliding, sliding, app("New")])

        var readAt: TimeInterval = -1
        let outcome = try run(timeline, read: { readAt = timeline.time; return app("New") })

        #expect(outcome?.changed == true)
        #expect(readAt >= 0.5)
        #expect(timeline.count >= 7)
    }

    @Test func `should not wait long for something that always sits across the edge`() throws {
        let carousel = app("Carousel", sliding: true)
        let timeline = Timeline([app("Old"), carousel])

        var readAt: TimeInterval = -1
        _ = try run(timeline, read: { readAt = timeline.time; return carousel })

        #expect(readAt < 1.5)
    }

    @Test func `should wait for the app to show something after a change`() throws {
        let timeline = Timeline([app("Sheet"), nothing(), nothing(), nothing(), nothing(), nothing(), app("Home")])

        var readAt: TimeInterval = -1
        let outcome = try run(timeline, read: { readAt = timeline.time; return app("Home") })

        #expect(outcome?.changed == true)
        #expect(readAt >= 0.5)
    }

    @Test func `should not slow a change where nothing is sliding`() throws {
        let timeline = Timeline([app("Old"), app("New")])

        var readAt: TimeInterval = -1
        _ = try run(timeline, read: { readAt = timeline.time; return app("New") })

        #expect(readAt <= 0.3)
    }

    @Test func `should stop watching a screen that never stops moving`() throws {
        let frames = (0..<100).map { screen("frame \($0)") }
        let timeline = Timeline(frames)
        let outcome = try run(timeline)

        #expect(outcome?.changed == true)
        #expect(timeline.time >= 3)
        #expect(timeline.time < 3.2)
    }

    @Test func `should not wait or read when the action failed`() throws {
        let timeline = Timeline([screen("A")])
        var reads = 0
        let outcome = try run(timeline, act: { false }, read: { reads += 1; return nil })

        #expect(outcome == nil)
        #expect(timeline.time == 0)
        #expect(reads == 0)
    }

    @Test func `should look before acting so the action is what it compares against`() throws {
        let timeline = Timeline([screen("A")])
        var glancesWhenActing = -1
        _ = try run(timeline, act: { glancesWhenActing = timeline.count; return true })

        #expect(glancesWhenActing == 1)
    }

    @Test func `should count an app appearing as a change`() throws {
        let timeline = Timeline([nil, screen("A")])
        let outcome = try run(timeline)

        #expect(outcome?.changed == true)
    }
}
