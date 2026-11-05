import Testing
import Foundation
@testable import Baguette

/// After a launch, an agent wants the app's first real screen. A new app
/// can show the bridge an empty tree until the guest helper wakes it, and
/// the old screen stays up until it takes over.
@Suite("AXFirstScreen")
struct AXFirstScreenTests {
    private static let frame = Rect(origin: Point(x: 0, y: 0), size: Size(width: 10, height: 10))
    private static let timing = AXFirstScreen.Timing(quiet: 0.2, patience: 1, limit: 5, poll: 0.1, wakeEvery: 1)

    private func screen(_ name: String, _ content: String? = "content") -> AXNode {
        AXNode(
            role: "AXApplication", label: name, frame: Self.frame,
            children: content.map { [AXNode(role: "AXButton", label: $0, frame: Self.frame)] } ?? [])
    }

    private final class Timeline {
        var time: TimeInterval = 0
        var glances: [AXNode?]
        var wakes: [TimeInterval] = []
        var reads = 0
        init(_ glances: [AXNode?]) { self.glances = glances }
        func glance() -> AXNode? { glances.count > 1 ? glances.removeFirst() : glances.first ?? nil }
    }

    private func run(_ t: Timeline, before: AXNode?) throws -> AXSettle.Outcome {
        try AXFirstScreen.run(
            before: before, glance: t.glance, wake: { t.wakes.append(t.time) },
            read: { t.reads += 1; return t.glance() }, timing: Self.timing,
            now: { t.time }, sleep: { t.time += $0 })
    }

    @Test func `should return the first screen once the new app has drawn and held still`() throws {
        let timeline = Timeline([screen("Home"), screen("Skylark")])
        let outcome = try run(timeline, before: screen("Home"))

        #expect(outcome.changed)
        #expect(outcome.tree == screen("Skylark"))
        #expect(timeline.reads == 1)
        #expect(timeline.time < 0.5)
    }

    @Test func `should keep waiting while the new app is still drawing`() throws {
        let timeline = Timeline(["Skylark a", "Skylark b", "Skylark c", "Skylark c"].map { screen("Skylark", $0) })
        _ = try run(timeline, before: screen("Home"))

        #expect(timeline.time >= 0.4)
    }

    @Test func `should wake an app once it shows up empty, not before`() throws {
        let timeline = Timeline([screen("Home"), screen("Home"), screen("Skylark", nil), screen("Skylark")])
        let outcome = try run(timeline, before: screen("Home"))

        #expect(timeline.wakes == [0.2])
        #expect(outcome.tree == screen("Skylark"))
    }

    @Test func `should not wake anything when the new app is readable already`() throws {
        let timeline = Timeline([screen("Skylark")])
        _ = try run(timeline, before: screen("Home"))

        #expect(timeline.wakes.isEmpty)
    }

    @Test func `should wake it again if it is still empty after a while`() throws {
        var glances: [AXNode?] = Array(repeating: screen("Skylark", nil), count: 25)
        glances.append(screen("Skylark"))
        let timeline = Timeline(glances)
        _ = try run(timeline, before: screen("Home"))

        #expect(timeline.wakes.count >= 2)
        #expect(timeline.wakes[1] - timeline.wakes[0] >= 1)
    }

    @Test func `should not mistake the previous screen moving for the new app`() throws {
        let moved = screen("Home", "moved")
        var glances: [AXNode?] = Array(repeating: moved, count: 5)
        glances.append(screen("Skylark"))
        let timeline = Timeline(glances)
        let outcome = try run(timeline, before: screen("Home"))

        #expect(outcome.tree == screen("Skylark"))
    }

    @Test func `should return after a short wait when the app was already in front`() throws {
        let timeline = Timeline([screen("Skylark")])
        let outcome = try run(timeline, before: screen("Skylark"))

        #expect(!outcome.changed)
        #expect(timeline.time >= 1)
        #expect(timeline.time < 1.2)
    }

    @Test func `should stop waiting at the limit`() throws {
        let timeline = Timeline([screen("Skylark", nil)])
        let outcome = try run(timeline, before: screen("Home"))

        #expect(timeline.time >= 5)
        #expect(timeline.time < 5.2)
        #expect(outcome.changed)
    }

    @Test func `should see an app appear on a device with nothing frontmost`() throws {
        let timeline = Timeline([nil, screen("Skylark")])
        let outcome = try run(timeline, before: nil)

        #expect(outcome.tree == screen("Skylark"))
    }
}
