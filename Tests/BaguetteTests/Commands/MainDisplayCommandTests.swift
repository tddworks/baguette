import ArgumentParser
import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `baguette main-display`, which `serve --share-mac` runs to make a shared
/// display main or give main back: its exit says whether it took.
@Suite("MainDisplayCommand")
struct MainDisplayCommandTests {
    /// A session whose main display is `main`, whatever is placed.
    func configuration(main: UInt32) -> MockDisplayConfiguration {
        let configuration = MockDisplayConfiguration()
        given(configuration).main.willReturn(main)
        given(configuration).origins().willReturn([1: Point(x: 0, y: 0), 47: Point(x: 1920, y: 0)])
        given(configuration).place(.any).willReturn()
        return configuration
    }

    @Test func `should exit once the display is main`() throws {
        try MainDisplayCommand.parse(["--display", "47"]).makeMain(with: configuration(main: 47), pause: { _ in })
    }

    @Test func `should exit failed when the display never becomes main`() throws {
        #expect(throws: ExitCode.failure) {
            try MainDisplayCommand.parse(["--display", "47"]).makeMain(with: configuration(main: 1), pause: { _ in })
        }
    }
}
