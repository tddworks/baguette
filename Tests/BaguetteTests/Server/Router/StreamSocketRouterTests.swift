import CoreVideo
import Foundation
import HTTPTypes
import HummingbirdTesting
import HummingbirdWSTesting
import IOSurface
import Mockable
import Testing
import WSClient
@testable import Baguette
@testable import BaguetteDevice

/// One socket conversation: open `path`, send `lines`, and collect every
/// text message until `done` says the conversation has said enough — or
/// the server closes it.
func socketConversation(
    _ path: String,
    server: InProcessServer,
    sending lines: [String] = [],
    binary: [Data] = [],
    until done: @escaping @Sendable (String) -> Bool = { _ in false }
) async throws -> [String] {
    let received = Received()
    try await server.live { client in
        try await client.ws(path) { inbound, outbound, _ in
            for line in lines { try await outbound.write(.text(line)) }
            for chunk in binary { try await outbound.write(.binary(.init(data: chunk))) }
            for try await message in inbound.messages(maxSize: 1 << 24) {
                guard case .text(let text) = message else { continue }
                received.append(text)
                if done(text) { return }
            }
        }
    }
    return received.all
}

/// A server whose sockets the test client may open: its Origin is a bare
/// `http://localhost`, no port, so `localhost` is an allowed host.
private func socketServer(
    devices: any Devices = routeDevices(), models: any DeviceModels = MockDeviceModels()
) -> InProcessServer {
    let chromes = MockChromes()
    given(chromes).panels(forDeviceName: .any).willReturn([.primary])
    return InProcessServer(devices: devices, chromes: chromes, models: models, allowedHosts: ["localhost"])
}

/// The live frame stream and the 3D stream, as their sockets answer.
@Suite("Serve router: stream sockets")
struct StreamSocketRouterTests {

    private static func screen() -> MockScreen {
        let surface = IOSurface(properties: [
            .width: 40, .height: 80, .bytesPerElement: 4, .bytesPerRow: 160,
            .pixelFormat: kCVPixelFormatType_32BGRA, .allocSize: 40 * 80 * 4,
        ])!
        let screen = MockScreen()
        given(screen).start(onFrame: .any).willProduce { onFrame in onFrame(surface) }
        given(screen).stop().willReturn(())
        return screen
    }

    @Test func `should refuse to open a socket for a page on another origin`() async throws {
        await #expect(throws: (any Error).self) {
            try await InProcessServer().live { client in
                try await client.ws("/simulators/U/stream") { _, _, _ in }
            }
        }
    }

    @Test func `should say so on the stream socket when no device has the id`() async throws {
        for path in ["/simulators/ghost/stream", "/devices/ghost/stream"] {
            let messages = try await socketConversation(path, server: socketServer())

            #expect(messages == [#"{"ok":false,"error":"unknown udid"}"#], "\(path)")
        }
    }

    @Test func `should refuse a stream that asks for an existing display ambiguously`() async throws {
        let messages = try await socketConversation(
            "/simulators/U/stream?requireExistingDisplay=maybe", server: socketServer())

        #expect(messages == [#"{"ok":false,"error":"invalid requireExistingDisplay"}"#])
    }

    @Test func `should say why a device with no screen can't stream`() async throws {
        let messages = try await socketConversation("/simulators/U/stream", server: socketServer())

        #expect(messages.count == 1)
        #expect(messages.first?.hasPrefix(#"{"ok":false"#) == true)
    }

    @Test func `should stream a device's screen and answer what the page asks over the socket`() async throws {
        let ax = MockAccessibility()
        given(ax).describeAll().willReturn(AXNode(
            role: "AXApplication", frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 10, height: 10))))
        given(ax).describeAt(point: .any).willThrow(RoleFailed())
        let input = InputMocks()
        given(input.touch).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(true)
        let devices = routeDevices {
            $0 = .input(of: "iPhone 17", all: input)
            $0.register(.screen) { Self.screen() }
            $0.register(.accessibility) { ax }
        }

        let messages = try await socketConversation(
            "/simulators/U/stream?format=mjpeg", server: socketServer(devices: devices),
            sending: [
                #"{"type":"set_fps","fps":30}"#,
                #"{"type":"force_idr"}"#,
                #"{"type":"snapshot"}"#,
                #"{"type":"tap","x":1,"y":2,"width":10,"height":20}"#,
                #"{"type":"describe_ui","x":1,"y":1}"#,
                #"{"type":"describe_ui"}"#,
            ],
            until: { $0.contains(#""ok":true"#) && $0.contains("describe_ui_result") })

        #expect(messages.contains { $0.hasPrefix(#"{"type":"describe_ui_result","ok":false"#) })
        #expect(messages.last?.contains("AXApplication") == true)
    }

    @Test func `should say so on the camera socket when the device has no camera or doesn't exist`() async throws {
        let none = try await socketConversation("/devices/U/camera", server: socketServer())
        let ghost = try await socketConversation("/simulators/ghost/camera", server: socketServer())

        #expect(none.count == 1)
        #expect(none.first?.hasPrefix(#"{"type":"camera_state","ok":false"#) == true)
        #expect(ghost == [#"{"type":"camera_state","ok":false,"error":"unknown udid"}"#])
    }

    // MARK: - 3D

    @Test func `should refuse 3D stream options it can't read`() async throws {
        let messages = try await socketConversation(
            "/simulators/U/stream.3d.mjpeg?width=0", server: socketServer())

        #expect(messages == [#"{"ok":false,"error":"invalid live 3D stream options"}"#])
    }

    @Test func `should say so on the 3D socket when no device has the id or it has no model`() async throws {
        let models = MockDeviceModels()
        given(models).match(deviceType: .any, deviceName: .any).willReturn(nil)

        let ghost = try await socketConversation(
            "/simulators/ghost/stream.3d.avcc", server: socketServer(models: models))
        let noModel = try await socketConversation(
            "/devices/U/stream.3d.mjpeg", server: socketServer(models: models))

        #expect(ghost == [#"{"ok":false,"error":"unknown udid"}"#])
        #expect(noModel.count == 1)
        #expect(noModel.first?.hasPrefix(#"{"ok":false"#) == true)
    }
}

/// The companion app's sockets: it says hello, then sends attitude or
/// video; a hello for another device is refused.
@Suite("Serve router: companion sockets")
struct CompanionSocketRouterTests {

    private static let hello = #"{"type":"hello","udid":"U1","name":"iPhone","model":"iPhone17,2","capabilities":["motion","screen"]}"#

    @Test func `should register a companion that says hello on its motion socket`() async throws {
        let messages = try await socketConversation(
            "/devices/U1/companion/motion", server: socketServer(),
            sending: [Self.hello, #"{"type":"attitude","q":[0,0,0,1],"t":1.5}"#,
                      #"{"type":"attitude","q":[0,0,0,1],"t":1.6}"#],
            until: { $0 == #"{"ok":true}"# })

        #expect(messages == [#"{"ok":true}"#])
    }

    @Test func `should refuse a hello for a device the socket isn't for`() async throws {
        let hello = #"{"type":"hello","udid":"OTHER","name":"iPhone","model":"iPhone17,2"}"#

        let motion = try await socketConversation(
            "/devices/U1/companion/motion", server: socketServer(), sending: [hello],
            until: { _ in true })
        let video = try await socketConversation(
            "/devices/U1/companion/video", server: socketServer(), sending: [hello],
            until: { _ in true })

        #expect(motion.first?.contains(#""ok":false"#) == true)
        #expect(video.first?.contains(#""ok":false"#) == true)
    }

    @Test func `should open a companion's video once it says hello and names its format`() async throws {
        let messages = try await socketConversation(
            "/devices/U1/companion/video", server: socketServer(),
            sending: [Self.hello, #"{"type":"format","width":1290,"height":2796,"codec":"avcc"}"#],
            binary: [Data([0, 0, 0, 1])],
            until: { $0 == #"{"ok":true}"# })

        #expect(messages == [#"{"ok":true}"#])
    }
}
