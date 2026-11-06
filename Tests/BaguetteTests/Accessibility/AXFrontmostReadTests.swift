import Testing
import Foundation
@testable import Baguette

/// The bridge answers in milliseconds but a freshly launched app can
/// show it an empty tree until a guest AX client has connected, so the
/// guest helper (about half a second) runs only when the bridge alone
/// could not read the app.
@Suite("AXFrontmostRead")
struct AXFrontmostReadTests {
    private struct GuestDown: Error, Equatable {}

    private func tree(children: Int) -> AXNode {
        let frame = Rect(origin: Point(x: 0, y: 100), size: Size(width: 10, height: 10))
        return AXNode(
            role: "AXApplication", frame: frame,
            children: (0..<children).map { _ in AXNode(role: "AXButton", frame: frame) })
    }

    @Test func `should read the tree through the bridge when the app answers`() throws {
        var guestRuns = 0
        let result = try AXFrontmostRead.read(
            bridge: { 7 },
            guest: { guestRuns += 1; return 9 },
            tree: { pid, source in
                #expect(pid == 7)
                #expect(source == .bridge)
                return tree(children: 3)
            })

        #expect(result?.children.count == 3)
        #expect(guestRuns == 0)
    }

    @Test func `should wake the app through the guest helper when the bridge finds an empty tree`() throws {
        var reads: [(Int32, AXFrontmostRead.Source)] = []
        let result = try AXFrontmostRead.read(
            bridge: { 7 },
            guest: { 7 },
            tree: { pid, source in
                reads.append((pid, source))
                return tree(children: source == .bridge ? 0 : 2)
            })

        #expect(result?.children.count == 2)
        #expect(reads.map(\.1) == [.bridge, .guest])
    }

    @Test func `should ask the guest helper when the bridge names no app`() throws {
        for answer: Int32? in [nil, 0, -1] {
            var sources: [AXFrontmostRead.Source] = []
            let result = try AXFrontmostRead.read(
                bridge: { answer },
                guest: { 9 },
                tree: { pid, source in
                    #expect(pid == 9)
                    sources.append(source)
                    return tree(children: 1)
                })

            #expect(result?.children.count == 1)
            #expect(sources == [.guest])
        }
    }

    @Test func `should ask the guest helper when the bridge cannot read the app it named`() throws {
        var sources: [AXFrontmostRead.Source] = []
        let result = try AXFrontmostRead.read(
            bridge: { 7 },
            guest: { 7 },
            tree: { _, source in
                sources.append(source)
                if source == .bridge { throw GuestDown() }
                return tree(children: 1)
            })

        #expect(result?.children.count == 1)
        #expect(sources == [.bridge, .guest])
    }

    @Test func `should surface the failure when the guest helper fails too`() {
        #expect(throws: GuestDown()) {
            try AXFrontmostRead.read(
                bridge: { nil },
                guest: { throw GuestDown() },
                tree: { _, _ in tree(children: 1) })
        }
    }

    @Test func `should report an empty tree when the guest helper finds one too`() throws {
        let result = try AXFrontmostRead.read(
            bridge: { 7 }, guest: { 7 }, tree: { _, _ in tree(children: 0) })

        #expect(result?.children.isEmpty == true)
    }

    // MARK: - an app the guest client just woke

    private static let statusBar = AXNode(
        role: "AXStaticText", label: "7:04 PM",
        frame: Rect(origin: Point(x: 54, y: 21), size: Size(width: 40, height: 22)))
    private static let button = AXNode(
        role: "AXButton", label: "Sign In",
        frame: Rect(origin: Point(x: 16, y: 324), size: Size(width: 370, height: 52)))
    private static let whole = Rect(origin: Point(x: 0, y: 0), size: Size(width: 402, height: 874))
    private static let asleep = AXNode(role: "AXApplication", frame: whole, children: [statusBar])
    private static let awake = AXNode(role: "AXApplication", frame: whole, children: [statusBar, button])
    private static let brief = AXFrontmostRead.Timing(wake: 1, poll: 0.1)

    /// A clock that moves only when the read sleeps, so no test waits.
    private final class Clock: @unchecked Sendable {
        var time = 0.0
        var sleeps = 0
    }

    private func read(answers: [AXNode], clock: Clock = Clock()) throws -> (AXNode?, Clock) {
        var queue = answers
        let answer = try AXFrontmostRead.read(
            bridge: { nil },
            guest: { 7 },
            tree: { _, _ in queue.count > 1 ? queue.removeFirst() : queue.first },
            timing: Self.brief,
            now: { clock.time },
            sleep: { clock.time += $0; clock.sleeps += 1 })
        return (answer, clock)
    }

    @Test func `should wait for an app the guest client just woke`() throws {
        let (answer, _) = try read(answers: [Self.asleep, Self.asleep, Self.awake])

        #expect(answer == Self.awake)
    }

    @Test func `should not wait when the guest read already shows the app`() throws {
        let (answer, clock) = try read(answers: [Self.awake])

        #expect(answer == Self.awake)
        #expect(clock.sleeps == 0)
    }

    @Test func `should answer with what it has when an app never shows more than the status bar`() throws {
        let (answer, clock) = try read(answers: [Self.asleep])

        #expect(answer == Self.asleep)
        #expect(clock.time >= Self.brief.wake)
        #expect(clock.time < Self.brief.wake + 1)
    }

    @Test func `should know a screen with only the status bar from one with an app on it`() {
        #expect(Self.asleep.showsOnlyTheStatusBar)
        #expect(!Self.awake.showsOnlyTheStatusBar)
    }
}
