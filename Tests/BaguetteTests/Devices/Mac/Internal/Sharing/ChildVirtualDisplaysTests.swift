import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// Each shared display in a process of its own (`baguette virtual-display`):
/// a process can set up only the first virtual display it makes, and its
/// display goes when it does.
@Suite("ChildVirtualDisplays")
struct ChildVirtualDisplaysTests {
    static let shape = SharedScreenShape(viewer: ViewerScreen(points: Size(width: 402, height: 874), pixelsPerPoint: 3),
                                         room: .standard)
    static let baguette = URL(fileURLWithPath: "/usr/local/bin/baguette")

    /// A child process played by the test: it says `says` as soon as it runs.
    final class Child: @unchecked Sendable {
        let process = MockSubprocess()
        private let lock = NSLock()
        private var _arguments: [String] = []
        private var _terminated = 0
        var arguments: [String] { lock.withLock { _arguments } }
        var terminated: Int { lock.withLock { _terminated } }

        init(says: String?, exits: Bool = false) {
            given(process).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any)
                .willProduce { [self] _, arguments, onBytes, onExit in
                    lock.withLock { _arguments = arguments }
                    if let says { onBytes(Data(says.utf8)) }
                    if exits { onExit(1) }
                }
            given(process).terminate().willProduce { [self] in lock.withLock { _terminated += 1 } }
        }

        func displays(wait: TimeInterval = 1, listed: @escaping @Sendable (UInt32) -> Bool = { _ in false })
            -> ChildVirtualDisplays {
            ChildVirtualDisplays(executable: ChildVirtualDisplaysTests.baguette, makeProcess: { self.process },
                                 wait: wait, isListed: listed)
        }
    }

    @Test func `should make a display through a process of its own, known by what the process announces`() throws {
        let child = Child(says: "[baguette] starting\nready 28 VIRTUAL-UUID\n")
        let display = try #require(child.displays().create(named: "baguette – iPhone", shape: Self.shape, serial: 3))
        #expect(display.id == 28)
        #expect(display.uuid == "VIRTUAL-UUID")
        #expect(child.arguments == ["virtual-display", "--name", "baguette – iPhone",
                                    "--width", "603", "--height", "1311", "--serial", "3"])
    }

    @Test func `should remove the display by ending its process`() throws {
        let child = Child(says: "ready 28 VIRTUAL-UUID\n")
        let display = try #require(child.displays().create(named: "n", shape: Self.shape, serial: 1))
        display.remove()
        #expect(child.terminated == 1)
    }

    @Test func `should finish removing a display only once the Mac no longer lists it`() throws {
        let child = Child(says: "ready 28 VIRTUAL-UUID\n")
        let looks = Looks(listedFor: 3)
        let display = try #require(child.displays(listed: looks.listed).create(named: "n", shape: Self.shape, serial: 1))
        display.remove()
        #expect(looks.asked == 4)
        #expect(looks.ids == [28, 28, 28, 28])
    }

    /// The Mac's display list, still listing the display for `listedFor` looks.
    final class Looks: @unchecked Sendable {
        private let lock = NSLock()
        private let listedFor: Int
        private var _ids: [UInt32] = []
        var asked: Int { lock.withLock { _ids.count } }
        var ids: [UInt32] { lock.withLock { _ids } }
        init(listedFor: Int) { self.listedFor = listedFor }
        func listed(_ id: UInt32) -> Bool { lock.withLock { _ids.append(id); return _ids.count <= listedFor } }
    }

    @Test func `should make no display when its process says it made none`() {
        let child = Child(says: "failed the 2x mode never came\n")
        #expect(child.displays().create(named: "n", shape: Self.shape, serial: 1) == nil)
        #expect(child.terminated == 1)
    }

    @Test func `should make no display when its process ends before announcing one`() {
        let child = Child(says: nil, exits: true)
        #expect(child.displays().create(named: "n", shape: Self.shape, serial: 1) == nil)
    }

    @Test func `should give up on a process that announces nothing in time, ending it`() {
        let child = Child(says: nil)
        #expect(child.displays(wait: 0.05).create(named: "n", shape: Self.shape, serial: 1) == nil)
        #expect(child.terminated == 1)
    }
}
