import Foundation
import IOSurface
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// An emulator's screen through its control API: the emulator draws each
/// picture into memory it shares with baguette and sends only a notice —
/// with its link and that memory stood in for.
@Suite("EmulatorScreen")
struct EmulatorScreenTests {
    private static let emulator = RunningEmulator(serial: "emulator-5554", avd: "baguette_pixel", port: 8554, token: "tok")
    private static let screenPixels = Size(width: 2, height: 1)

    private final class Signal: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        func fire() { semaphore.signal() }
        func wait() -> Bool { semaphore.wait(timeout: .now() + 5) == .success }
    }

    private final class Link: @unchecked Sendable {
        let link = MockEmulatorLink()
        private let lock = NSLock()
        private var inbound: [Data]
        private var _sent = Data()
        var sent: Data { lock.withLock { _sent } }

        init(_ inbound: [Data]) {
            self.inbound = inbound
            given(link).send(.any).willProduce { [self] data in lock.withLock { _sent += data } }
            given(link).receive().willProduce { [self] in
                let next = lock.withLock { self.inbound.isEmpty ? nil : self.inbound.removeFirst() }
                if next == nil { Thread.sleep(forTimeInterval: 0.002) }
                return next
            }
            given(link).close().willReturn()
        }
    }

    /// The memory the emulator draws into: red, then blue, as RGBA.
    private final class Memory: @unchecked Sendable {
        let shared = MockSharedPicture()
        let buffer: UnsafeMutableRawPointer
        let made = Signal()
        private let lock = NSLock()
        private var _capacities: [Int] = []
        var capacities: [Int] { lock.withLock { _capacities } }

        init(holding pixels: [UInt8] = [0xFF, 0, 0, 0xFF, 0, 0, 0xFF, 0xFF]) {
            buffer = .allocate(byteCount: pixels.count, alignment: 16)
            buffer.copyMemory(from: pixels, byteCount: pixels.count)
            given(shared).handle.willReturn("file:///tmp/baguette-picture")
            given(shared).capacity.willReturn(pixels.count)
            given(shared).pixels.willReturn(UnsafeRawPointer(buffer))
            given(shared).close().willReturn()
        }

        func make(_ capacity: Int) -> any SharedPicture {
            lock.withLock { _capacities.append(capacity) }
            return shared
        }
    }

    /// The emulator's notice of a picture of `width` × `height` drawn into shared memory, on stream 1.
    private static func notice(width: UInt8 = 2, height: UInt8 = 1) -> Data {
        let image = Data([0x0A, 0x06, 0x08, 0x01, 0x18, width, 0x20, height, 0x28, 0x01])
        return GRPCFrame.bytes(kind: 0, flags: 0, stream: 1, Data([0, 0, 0, 0, UInt8(image.count)]) + image)
    }

    private func screen(_ link: Link, _ memory: Memory) -> EmulatorScreen {
        EmulatorScreen(emulator: Self.emulator, screen: Self.screenPixels,
                       connect: { EmulatorConnection(to: $0, openLink: { _ in link.link }) },
                       share: { memory.make($0) }, pause: { _ in })
    }

    @Test func `should ask the emulator to draw its pictures into memory it shares, a screen's worth`() throws {
        let link = Link([])
        let memory = Memory()
        let screen = screen(link, memory)

        try screen.start { _ in }
        screen.stop()

        let call = GRPCCall(method: "streamScreenshot", stream: 1, authority: "localhost:8554", token: "tok",
                            message: EmulatorControl.ImageFormat(format: .rgba8888,
                                                                 sharedMemory: "file:///tmp/baguette-picture").bytes).bytes
        #expect(link.sent.range(of: call) != nil)
        #expect(memory.capacities == [2 * 1 * 4])
    }

    @Test func `should hand each picture on from the shared memory, as the emulator's notice sizes it`() throws {
        let memory = Memory()
        let screen = screen(Link([Self.notice()]), memory)
        let got = Signal()
        let firstPixels = Pixels()

        try screen.start { surface in
            surface.lock(options: .readOnly, seed: nil)
            let out = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
            firstPixels.set((surface.width, surface.height, (0..<4).map { out[$0] }))
            surface.unlock(options: .readOnly, seed: nil)
            got.fire()
        }

        #expect(got.wait())
        screen.stop()
        #expect(firstPixels.value?.0 == 2)
        #expect(firstPixels.value?.1 == 1)
        #expect(firstPixels.value?.2 == [0, 0, 0xFF, 0xFF])   // red, as BGRA
    }

    @Test func `should hand on no picture larger than the memory it shares`() throws {
        let memory = Memory()
        let screen = screen(Link([Self.notice(width: 100, height: 100), Self.notice()]), memory)
        let sizes = Pixels()
        let got = Signal()

        try screen.start { surface in
            sizes.set((surface.width, surface.height, []))
            got.fire()
        }

        #expect(got.wait())
        screen.stop()
        #expect(sizes.value?.0 == 2)
    }

    @Test func `should let go of the shared memory and its connection when stopped`() throws {
        let link = Link([])
        let memory = Memory()
        let screen = screen(link, memory)
        try screen.start { _ in }

        screen.stop()

        verify(link.link).close().called(1)
        verify(memory.shared).close().called(1)
    }

    @Test func `should start the feed again when the emulator ends it, into the same memory`() throws {
        let ended = MockEmulatorLink()
        given(ended).send(.any).willReturn()
        given(ended).receive().willThrow(Closed())
        given(ended).close().willReturn()
        let fresh = Link([Self.notice()])
        let links = Links([ended, fresh.link])
        let memory = Memory()
        let screen = EmulatorScreen(emulator: Self.emulator, screen: Self.screenPixels,
                                    connect: { EmulatorConnection(to: $0, openLink: { _ in links.next() }) },
                                    share: { memory.make($0) }, pause: { _ in })
        let got = Signal()

        try screen.start { _ in got.fire() }

        #expect(got.wait())
        screen.stop()
        #expect(memory.capacities.count == 1)
    }

    @Test func `should not start the feed again once stopped`() throws {
        let ended = MockEmulatorLink()
        given(ended).send(.any).willReturn()
        given(ended).receive().willProduce { Thread.sleep(forTimeInterval: 0.05); throw Closed() }
        given(ended).close().willReturn()
        let connects = Counter()
        let memory = Memory()
        let screen = EmulatorScreen(emulator: Self.emulator, screen: Self.screenPixels,
                                    connect: { connects.add(); return EmulatorConnection(to: $0, openLink: { _ in ended }) },
                                    share: { memory.make($0) }, pause: { _ in })

        try screen.start { _ in }
        screen.stop()
        Thread.sleep(forTimeInterval: 0.2)

        #expect(connects.count == 1)
    }

    private struct Closed: Error {}

    /// Hands out the links in order, the last one again once they run out.
    private final class Links: @unchecked Sendable {
        private let lock = NSLock()
        private var links: [any EmulatorLink]
        init(_ links: [any EmulatorLink]) { self.links = links }
        func next() -> any EmulatorLink { lock.withLock { links.count > 1 ? links.removeFirst() : links[0] } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func add() { lock.withLock { _count += 1 } }
    }

    private final class Pixels: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: (Int, Int, [UInt8])?
        var value: (Int, Int, [UInt8])? { lock.withLock { _value } }
        func set(_ value: (Int, Int, [UInt8])) { lock.withLock { if _value == nil { _value = value } } }
    }
}
