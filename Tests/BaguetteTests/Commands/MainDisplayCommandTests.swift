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
        given(configuration).bounds().willReturn([
            1: Rect(origin: Point(x: 0, y: 0), size: Size(width: 1920, height: 1080)),
            47: Rect(origin: Point(x: 1920, y: 0), size: Size(width: 603, height: 1311)),
        ])
        return configuration
    }

    @Test func `should exit once the display is main`() throws {
        let configuration = configuration(main: 47)
        given(configuration).place(.any).willReturn()
        try MainDisplayCommand.parse(["--display", "47"]).makeMain(with: configuration, pause: { _ in })
    }

    @Test func `should exit failed when the display never becomes main`() throws {
        let configuration = configuration(main: 1)
        given(configuration).place(.any).willReturn()
        #expect(throws: ExitCode.failure) {
            try MainDisplayCommand.parse(["--display", "47"]).makeMain(with: configuration, pause: { _ in })
        }
    }

    @Test func `should keep the Dock's edge free when asked, on the side macOS says the Dock is`() throws {
        let command = try MainDisplayCommand.parse(["--display", "47", "--free-dock"])
        #expect(command.freeDock)
        let placed = Placed()
        let configuration = configuration(main: 1)
        given(configuration).place(.any).willProduce { placed.add($0) }
        try? command.makeMain(with: configuration, dockOrientation: { "right" }, pause: { _ in })
        #expect(placed.first?[47] == Point(x: 0, y: 0))
        #expect(placed.first?[1] == Point(x: -1920, y: 0))
    }

    @Test func `should only shift the arrangement when not asked to free the Dock's edge`() throws {
        let command = try MainDisplayCommand.parse(["--display", "47"])
        #expect(!command.freeDock)
        let placed = Placed()
        let configuration = configuration(main: 1)
        given(configuration).place(.any).willProduce { placed.add($0) }
        try? command.makeMain(with: configuration, dockOrientation: { "right" }, pause: { _ in })
        #expect(placed.first?[47] == Point(x: 0, y: 0))
        #expect(placed.first?[1] == Point(x: -1920, y: 0))
    }

    final class Placed: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [[UInt32: Point]] = []
        var first: [UInt32: Point]? { lock.withLock { all.first } }
        func add(_ origins: [UInt32: Point]) { lock.withLock { all.append(origins) } }
    }
}
