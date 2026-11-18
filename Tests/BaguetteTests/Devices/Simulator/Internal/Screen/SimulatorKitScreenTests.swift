import Foundation
import IOSurface
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// A simulator screen as SimulatorKit composites it: callbacks on every
/// display framebuffer, the surface of this screen's plane handed on as
/// frames arrive, and the callbacks let go when the screen stops.
@Suite("SimulatorKitScreen")
struct SimulatorKitScreenTests {

    private func host(_ device: NSObject?) -> MockDeviceHost {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(device)
        return host
    }

    /// The surfaces a screen handed on, in order.
    private final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var surfaces: [IOSurface] = []
        private let arrived = DispatchSemaphore(value: 0)

        func take(_ surface: IOSurface) {
            lock.withLock { surfaces.append(surface) }
            arrived.signal()
        }

        /// Waits for `count` more frames, then answers every one so far.
        func await(_ count: Int = 1) -> [IOSurface] {
            for _ in 0..<count { _ = arrived.wait(timeout: .now() + 5) }
            return lock.withLock { surfaces }
        }

        /// Whether `surface` is handed on within a few seconds.
        func see(_ surface: IOSurface?) -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if lock.withLock({ surfaces.contains { $0 === surface } }) { return true }
                _ = arrived.wait(timeout: .now() + 0.1)
            }
            return false
        }
    }

    @Test func `should hand on the surface SimulatorKit composites when a frame arrives`() throws {
        let (device, descriptors) = FakeKit.device([(1206, 2622)])
        let screen = SimulatorKitScreen(udid: "u", host: host(device))
        let frames = Frames()

        try screen.start { frames.take($0) }
        defer { screen.stop() }
        _ = frames.await()
        descriptors[0].surface = FakeKit.surface(1206, 2622)
        descriptors[0].composite()

        #expect(frames.see(descriptors[0].surface))
    }

    @Test func `should hand on the new surface when SimulatorKit swaps a framebuffer's surfaces`() throws {
        let (device, descriptors) = FakeKit.device([(1206, 2622)])
        let screen = SimulatorKitScreen(udid: "u", host: host(device))
        let frames = Frames()

        try screen.start { frames.take($0) }
        defer { screen.stop() }
        _ = frames.await()
        descriptors[0].surface = FakeKit.surface(2622, 1206)
        descriptors[0].swapSurfaces()

        #expect(frames.see(descriptors[0].surface))
    }

    @Test func `should keep handing on the screen when nothing new is composited`() throws {
        let (device, _) = FakeKit.device([(1206, 2622)])
        let screen = SimulatorKitScreen(udid: "u", host: host(device))
        let frames = Frames()

        try screen.start { frames.take($0) }
        defer { screen.stop() }

        #expect(frames.await(3).count >= 3)
    }

    @Test func `should hand on the largest plane when the screen is bound to none`() throws {
        let (device, descriptors) = FakeKit.device([(720, 480), (1206, 2622), (100, 100)])
        let screen = SimulatorKitScreen(udid: "u", host: host(device))
        let frames = Frames()

        try screen.start { frames.take($0) }
        defer { screen.stop() }

        #expect(frames.await().first === descriptors[1].surface)
    }

    @Test func `should hand on the plane closest to its binding`() throws {
        let (device, descriptors) = FakeKit.device([(1206, 2622), (1920, 1080)])
        let binding = DisplayBinding(
            kind: .carPlay, connectedScreenId: 2, portName: "com.apple.framebuffer.display",
            size: Size(width: 1920, height: 1080), orientation: nil, panel: nil)
        let screen = SimulatorKitScreen(udid: "u", host: host(device), binding: binding)
        let frames = Frames()

        try screen.start { frames.take($0) }
        defer { screen.stop() }

        #expect(frames.await().first === descriptors[1].surface)
    }

    @Test func `should listen to every display framebuffer and let each go when stopped`() throws {
        let (device, descriptors) = FakeKit.device([(1206, 2622), (1920, 1080)])
        let screen = SimulatorKitScreen(udid: "u", host: host(device))

        try screen.start { _ in }
        #expect(descriptors.allSatisfy { $0.registered.count == 1 })
        screen.stop()

        #expect(descriptors.allSatisfy { $0.unregistered == $0.registered })
    }

    @Test func `should hand on nothing once stopped`() throws {
        let (device, descriptors) = FakeKit.device([(1206, 2622)])
        let screen = SimulatorKitScreen(udid: "u", host: host(device))
        let frames = Frames()

        try screen.start { frames.take($0) }
        let before = frames.await().count
        screen.stop()
        descriptors[0].composite()
        Thread.sleep(forTimeInterval: 0.3)

        #expect(frames.await(0).count <= before + 1)
    }

    @Test func `should ask SimulatorKit for its ports again when it lists no display framebuffer`() throws {
        let descriptor = FakeKitDescriptor(surface: FakeKit.surface(4, 8))
        let io = FakeKitIO(ports: [], afterUpdate: [FakeKitPort(descriptor: descriptor)])
        let screen = SimulatorKitScreen(udid: "u", host: host(FakeKitDevice(io: io)))

        try screen.start { _ in }
        screen.stop()

        #expect(io.updates == 1)
        #expect(descriptor.registered.count == 1)
    }

    @Test func `should not start when SimulatorKit lists no display framebuffer`() {
        let io = FakeKitIO(ports: [
            FakeKitPort("com.apple.hid", descriptor: FakeKitDescriptor(surface: nil)),
            FakeKitPort(descriptor: NSObject()),
            FakeKitPort(descriptor: nil),
            FakeKitBarePort(),
            NSObject(),
        ])
        let screen = SimulatorKitScreen(udid: "u", host: host(FakeKitDevice(io: io)))

        #expect(throws: ScreenError.noFramebuffer) { try screen.start { _ in } }
    }

    @Test func `should not start when a framebuffer takes no screen callbacks`() {
        let io = FakeKitIO(ports: [FakeKitPort(descriptor: FakeKitSilentDescriptor(surface: nil))])
        let screen = SimulatorKitScreen(udid: "u", host: host(FakeKitDevice(io: io)))

        #expect(throws: ScreenError.callbackUnavailable) { try screen.start { _ in } }
    }

    @Test func `should not start when the device has no IO`() {
        let screen = SimulatorKitScreen(udid: "u", host: host(FakeKitDevice(io: nil)))

        #expect(throws: ScreenError.ioUnavailable) { try screen.start { _ in } }
    }

    @Test func `should not start when the device is not in the set`() {
        let screen = SimulatorKitScreen(udid: "u", host: host(nil))

        #expect(throws: SimulatorError.notFound(udid: "u")) { try screen.start { _ in } }
    }
}
