import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import HummingbirdWebSocket
import Logging
import Mockable
import NIOCore
import NIOEmbedded
@testable import Baguette
@testable import BaguetteDevice

/// `baguette serve` driven in-process: the real router, every middleware
/// and route closure, answered without binding a port. Each collaborator
/// defaults to an unstubbed mock, so a route that reaches one a test
/// didn't set up fails loudly rather than touching a simulator.
struct InProcessServer {
    let server: Server

    init(
        devices: any Devices = routeDevices(),
        simulators: any Simulators = MockSimulators(),
        chromes: any Chromes = MockChromes(),
        macFrames: MacFrames = MacFrames(folder: URL(fileURLWithPath: "/nonexistent")) { _ in nil },
        screenShares: ScreenShares? = nil,
        pointerShapes: PointerShapes? = nil,
        models: any DeviceModels = MockDeviceModels(),
        deviceRenderer: any DeviceRenderer = MockDeviceRenderer(),
        plugins: any Plugins = MockPlugins(),
        allowedHosts: [String] = [],
        grants: PluginGrants = PluginGrants(),
        motionSessions: MotionSessions = MotionSessions(),
        cameraSessions: CameraSessions = CameraSessions(guestTerminated: { _ in false }),
        viewers: WebRTCViewers = WebRTCViewers(ticking: nil, connect: { _ in throw CancellationError() })
    ) {
        server = Server(
            simulators: simulators, chromes: chromes, macFrames: macFrames, screenShares: screenShares, pointerShapes: pointerShapes, models: models,
            deviceRenderer: deviceRenderer, plugins: plugins,
            allowedHosts: allowedHosts, grants: grants,
            motionSessions: motionSessions, cameraSessions: cameraSessions,
            allDevices: devices, viewers: viewers
        )
    }

    /// Run `body` against the router, as `.router` testing does: each
    /// request reaches the responder directly with authority `localhost`.
    func test<Value: Sendable>(
        _ body: @Sendable (any TestClientProtocol) async throws -> Value
    ) async throws -> Value {
        try await Application(router: server.makeRouter()).test(.router, body)
    }

    /// The same router behind a loopback listener on an ephemeral port,
    /// in this process — what a socket route needs, since `.router`
    /// testing can't upgrade one.
    func live<Value: Sendable>(
        _ body: @Sendable (any TestClientProtocol) async throws -> Value
    ) async throws -> Value {
        let router = server.makeRouter()
        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        return try await app.test(.live, body)
    }

    /// One request with a `Host` of the test's choosing — what the test
    /// clients can't send, since both pin the authority to `localhost`.
    func respond(
        _ method: HTTPRequest.Method, _ path: String,
        authority: String, headers: HTTPFields = [:]
    ) async throws -> Response {
        let responder = server.makeRouter().buildResponder()
        let request = Request(
            head: HTTPRequest(
                method: method, scheme: "http", authority: authority, path: path,
                headerFields: headers),
            body: .init(buffer: ByteBuffer()))
        let context = BasicWebSocketRequestContext(
            source: .init(channel: NIOAsyncTestingChannel(), logger: Logger(label: "test")))
        return try await responder.respond(to: request, context: context)
    }
}

/// One answer as a test reads it.
extension TestResponse {
    var text: String { String(buffer: body) }

    /// The body as a JSON object, or empty when it isn't one.
    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(buffer: body))) as? [String: Any] ?? [:]
    }

    func header(_ name: String) -> String? { headers[HTTPField.Name(name)!] }
}

extension TestClientProtocol {
    /// `method path` with an optional JSON/text body and extra headers.
    func send(
        _ method: HTTPRequest.Method, _ path: String,
        body: String? = nil, headers: HTTPFields = [:]
    ) async throws -> TestResponse {
        try await execute(
            uri: path, method: method, headers: headers,
            body: body.map { ByteBuffer(string: $0) }
        )
    }

    /// Just the status of `method path` — `599` when the request itself
    /// failed, which no route answers.
    func status(
        _ method: HTTPRequest.Method, _ path: String,
        body: String? = nil, headers: HTTPFields = [:]
    ) async -> HTTPResponse.Status {
        (try? await send(method, path, body: body, headers: headers))?.status ?? .init(code: 599)
    }
}

/// Both spellings of a per-device route: the devices tree and a
/// simulator's old one.
func bothTrees(_ leaf: String, udid: String = "U") -> [String] {
    ["/devices/\(udid)/\(leaf)", "/simulators/\(udid)/\(leaf)"]
}
