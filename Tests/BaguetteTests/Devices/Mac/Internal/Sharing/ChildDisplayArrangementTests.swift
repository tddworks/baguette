import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// The Mac's display arrangement, changed only by a short process of its own
/// (`baguette main-display`): a process that changes the arrangement stops
/// seeing displays added after it, so the server only ever reads it.
@Suite("ChildDisplayArrangement")
struct ChildDisplayArrangementTests {
    static let baguette = URL(fileURLWithPath: "/usr/local/bin/baguette")

    /// A `main-display` process played by the test: it ends with `exits`, or never.
    final class Child: @unchecked Sendable {
        let process = MockSubprocess()
        private let lock = NSLock()
        private var _arguments: [String] = []
        private var _terminated = 0
        var arguments: [String] { lock.withLock { _arguments } }
        var terminated: Int { lock.withLock { _terminated } }

        init(exits: Int32?) {
            given(process).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any)
                .willProduce { [self] _, arguments, _, onExit in
                    lock.withLock { _arguments = arguments }
                    if let exits { onExit(exits) }
                }
            given(process).terminate().willProduce { [self] in lock.withLock { _terminated += 1 } }
        }

        func arrangement(wait: TimeInterval = 1) -> ChildDisplayArrangement {
            ChildDisplayArrangement(executable: ChildDisplayArrangementTests.baguette, makeProcess: { self.process },
                                    readMain: { 3 }, wait: wait)
        }
    }

    @Test func `should read which display is main without a process`() {
        #expect(Child(exits: 0).arrangement().main == 3)
    }

    @Test func `should make a display main through a process of its own`() {
        let child = Child(exits: 0)
        #expect(child.arrangement().makeMain(47, freeingDock: false))
        #expect(child.arguments == ["main-display", "--display", "47"])
    }

    @Test func `should ask the process to keep the Dock's edge free when a share is made main`() {
        let child = Child(exits: 0)
        #expect(child.arrangement().makeMain(47, freeingDock: true))
        #expect(child.arguments == ["main-display", "--display", "47", "--free-dock"])
    }

    @Test func `should say the display didn't become main when its process says so`() {
        #expect(!Child(exits: 1).arrangement().makeMain(47, freeingDock: false))
    }

    @Test func `should give up on a process that doesn't finish in time, ending it`() {
        let child = Child(exits: nil)
        #expect(!child.arrangement(wait: 0.05).makeMain(47, freeingDock: false))
        #expect(child.terminated == 1)
    }
}
