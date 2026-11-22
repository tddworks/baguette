import ArgumentParser
import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `baguette virtual-display`, which `serve --share-mac` runs per share: it
/// says the display it made, then holds it; with none made, it says why.
@Suite("VirtualDisplayCommand")
struct VirtualDisplayCommandTests {
    final class Said: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        private var _held = false
        var lines: [String] { lock.withLock { _lines } }
        var held: Bool { lock.withLock { _held } }
        func say(_ line: String) { lock.withLock { _lines.append(line) } }
        func hold() { lock.withLock { _held = true } }
    }

    func virtualDisplay() throws -> VirtualDisplayCommand {
        try VirtualDisplayCommand.parse(["--name", "baguette – iPhone", "--width", "603", "--height", "1311", "--serial", "3"])
    }

    @Test func `should say the display it made, then hold it`() throws {
        let said = Said()
        try virtualDisplay().hold(make: { name, shape, serial in
            #expect(name == "baguette – iPhone" && serial == 3 && shape.points == Size(width: 603, height: 1311))
            return .ready(id: 7, uuid: "VIRTUAL-3")
        }, say: said.say, holdOn: said.hold)
        #expect(said.lines == ["ready 7 VIRTUAL-3"])
        #expect(said.held)
    }

    @Test func `should say why and exit failed, holding nothing, when the Mac makes no display`() throws {
        let said = Said()
        #expect(throws: ExitCode.failure) {
            try virtualDisplay().hold(make: { _, _, _ in .failed("no CGVirtualDisplay") }, say: said.say, holdOn: said.hold)
        }
        #expect(said.lines == ["failed no CGVirtualDisplay"])
        #expect(!said.held)
    }
}
