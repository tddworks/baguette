import Foundation
import IOSurface
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// An emulator's screen through its control API: one streamScreenshot call,
/// each picture handed on as a surface — with its link stood in for.
@Suite("EmulatorScreen")
struct EmulatorScreenTests {
    private static let emulator = RunningEmulator(serial: "emulator-5554", avd: "baguette_pixel", port: 8554, token: "tok")

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

    /// One Image message (2 × 1, RGBA) on stream 1, as the emulator streams it.
    private static let picture: Data = {
        let image = Data([0x0A, 0x06, 0x08, 0x01, 0x18, 0x02, 0x20, 0x01,
                          0x22, 0x08, 0xFF, 0, 0, 0xFF, 0, 0, 0xFF, 0xFF])
        let message = Data([0, 0, 0, 0, UInt8(image.count)]) + image
        return GRPCFrame.bytes(kind: 0, flags: 0, stream: 1, message)
    }()

    private func screen(_ link: Link) -> EmulatorScreen {
        EmulatorScreen(emulator: Self.emulator, connect: { EmulatorConnection(to: $0, openLink: { _ in link.link }) })
    }

    @Test func `should stream the emulator's screen as RGBA pictures`() throws {
        let link = Link([])
        let screen = screen(link)

        try screen.start { _ in }
        screen.stop()

        let call = GRPCCall(method: "streamScreenshot", stream: 1, authority: "localhost:8554", token: "tok",
                            message: EmulatorControl.ImageFormat(format: .rgba8888).bytes).bytes
        #expect(link.sent.range(of: call) != nil)
    }

    @Test func `should hand each picture the emulator streams on as a surface`() throws {
        let link = Link([Self.picture])
        let screen = screen(link)
        let got = Signal()
        let sizes = Sizes()

        try screen.start { surface in
            sizes.add(surface.width, surface.height)
            got.fire()
        }

        #expect(got.wait())
        screen.stop()
        #expect(sizes.all.first?.0 == 2)
        #expect(sizes.all.first?.1 == 1)
    }

    @Test func `should close its connection when stopped`() throws {
        let link = Link([])
        let screen = screen(link)
        try screen.start { _ in }

        screen.stop()

        verify(link.link).close().called(1)
    }

    private final class Sizes: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [(Int, Int)] = []
        var all: [(Int, Int)] { lock.withLock { _all } }
        func add(_ width: Int, _ height: Int) { lock.withLock { _all.append((width, height)) } }
    }
}
