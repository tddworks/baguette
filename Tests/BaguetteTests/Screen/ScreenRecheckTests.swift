import Testing
import Foundation
@testable import Baguette

/// After a read, the display is checked again so frames never describe
/// a screen that has since changed. Listing the connected screens spawns
/// `simctl`, which only a foldable needs: one panel can't change identity.
@Suite("ScreenRecheck")
struct ScreenRecheckTests {
    private static let portrait = AXScreen(width: 402, height: 874, orientation: .portrait)
    private static let landscape = AXScreen(width: 402, height: 874, orientation: .landscapeLeft)

    @Test func `should recheck a single panel from its live properties without observing it in full`() throws {
        var observations = 0
        let screen = try ScreenRecheck.read(
            multiplePanels: false,
            observe: { observations += 1; return Self.portrait },
            live: { Self.landscape })

        #expect(screen == Self.landscape)
        #expect(observations == 0)
    }

    @Test func `should observe a foldable in full because another panel can light`() throws {
        var liveReads = 0
        let screen = try ScreenRecheck.read(
            multiplePanels: true,
            observe: { Self.portrait },
            live: { liveReads += 1; return Self.landscape })

        #expect(screen == Self.portrait)
        #expect(liveReads == 0)
    }
}
