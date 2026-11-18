import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// One trusted bakery measured against what its remote holds now.
/// Pure — the network round-trip is the caller's problem, so every
/// state is driven by feeding a head in.
@Suite("BakeryUpdate")
struct BakeryUpdateTests {

    @Test func `should report a bakery still on its pinned commit as up to date`() {
        let update = BakeryUpdate(id: "github.com/acme/tools", pinned: "abc123", head: "abc123")
        #expect(update.state == .upToDate)
    }

    @Test func `should report an update available when a bakery's remote has moved`() {
        let update = BakeryUpdate(id: "github.com/acme/tools", pinned: "abc123", head: "def456")
        #expect(update.state == .available)
    }

    @Test func `should report a bakery as unreachable, never up to date, when its remote could not be reached`() {
        // The failure that matters: reporting "up to date" because the
        // network was down tells the user the opposite of the truth.
        let update = BakeryUpdate(id: "github.com/acme/tools", pinned: "abc123", head: nil)
        #expect(update.state == .unreachable)
    }

    @Test func `should flag only moved or unreachable bakeries as needing attention`() {
        let updates = [
            BakeryUpdate(id: "a", pinned: "1", head: "1"),
            BakeryUpdate(id: "b", pinned: "1", head: "2"),
            BakeryUpdate(id: "c", pinned: "1", head: nil),
        ]
        // Unreachable counts as needing attention: it's the one case
        // where we genuinely don't know.
        #expect(updates.filter { $0.state != .upToDate }.map(\.id) == ["b", "c"])
    }

    // MARK: - how it reads

    @Test func `should name both commits when an update is available`() {
        let line = BakeryUpdate(id: "github.com/acme/tools", pinned: "abc123def", head: "999888777").line
        #expect(line.contains("github.com/acme/tools"))
        #expect(line.contains("abc123d"))
        #expect(line.contains("9998887"))
    }

    @Test func `should say the bakery could not be reached rather than show a blank commit`() {
        let line = BakeryUpdate(id: "github.com/acme/tools", pinned: "abc123def", head: nil).line
        #expect(line.lowercased().contains("could not reach"))
    }
}
