import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// A device's display framebuffers as SimulatorKit lists them, read
/// through stand-in `io` / port / descriptor objects.
@Suite("SimulatorKitFramebuffers")
struct SimulatorKitFramebuffersTests {

    private func host(_ device: NSObject?) -> MockDeviceHost {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(device)
        return host
    }

    private func sizes(_ device: NSObject) throws -> [Size] {
        try SimulatorKitFramebuffers.sizedFramebuffers(udid: "u", host: host(device)).map(\.size)
    }

    @Test func `should size each display framebuffer from its live surface`() throws {
        let (device, _) = FakeKit.device([(1206, 2622), (1920, 1080)])

        #expect(try sizes(device) == [Size(width: 1206, height: 2622), Size(width: 1920, height: 1080)])
    }

    @Test func `should size a framebuffer from its port's defaults when nothing is composited yet`() throws {
        let io = FakeKitIO(ports: [
            FakeKitSizedPort(width: 720, height: 480, descriptor: FakeKitDescriptor(surface: nil)),
            FakeKitSizedPort(width: 800, height: 600, descriptor: NSObject()),
        ])

        #expect(try sizes(FakeKitDevice(io: io)) == [Size(width: 720, height: 480), Size(width: 800, height: 600)])
    }

    @Test func `should leave out a framebuffer that has neither a surface nor a default size`() throws {
        let io = FakeKitIO(ports: [
            FakeKitPort(descriptor: FakeKitDescriptor(surface: nil)),
            FakeKitPort(descriptor: NSObject()),
            FakeKitPort(descriptor: nil),
            FakeKitBarePort(),
            FakeKitPort(descriptor: FakeKitDescriptor(surface: FakeKit.surface(4, 8))),
        ])

        #expect(try sizes(FakeKitDevice(io: io)) == [Size(width: 4, height: 8)])
    }

    @Test func `should leave out ports that are not display framebuffers`() throws {
        let io = FakeKitIO(ports: [
            FakeKitPort("com.apple.hid", descriptor: FakeKitDescriptor(surface: FakeKit.surface(2, 2))),
            NSObject(),
            FakeKitPort(descriptor: FakeKitDescriptor(surface: FakeKit.surface(4, 8))),
        ])

        #expect(try sizes(FakeKitDevice(io: io)) == [Size(width: 4, height: 8)])
    }

    @Test func `should ask SimulatorKit for its ports again when it lists no display framebuffer`() throws {
        let port = FakeKitPort(descriptor: FakeKitDescriptor(surface: FakeKit.surface(4, 8)))
        let io = FakeKitIO(ports: [], afterUpdate: [port])

        #expect(try sizes(FakeKitDevice(io: io)) == [Size(width: 4, height: 8)])
        #expect(io.updates == 1)
    }

    @Test func `should not ask SimulatorKit for its ports again when it already lists a framebuffer`() throws {
        let port = FakeKitPort(descriptor: FakeKitDescriptor(surface: FakeKit.surface(4, 8)))
        let io = FakeKitIO(ports: [port])

        _ = try sizes(FakeKitDevice(io: io))

        #expect(io.updates == 0)
    }

    @Test func `should find no framebuffer when SimulatorKit lists none even when asked again`() {
        let io = FakeKitIO(ports: [])

        #expect(throws: ScreenError.noFramebuffer) { try sizes(FakeKitDevice(io: io)) }
        #expect(io.updates == 1)
    }

    @Test func `should find no framebuffer when the device has no IO`() {
        #expect(throws: ScreenError.ioUnavailable) { try sizes(FakeKitDevice(io: nil)) }
    }

    @Test func `should find no framebuffer when the device is not in the set`() {
        #expect(throws: SimulatorError.notFound(udid: "u")) {
            try SimulatorKitFramebuffers.sizedFramebuffers(udid: "u", host: host(nil))
        }
    }
}
