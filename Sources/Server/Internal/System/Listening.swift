import BaguetteDevice
import Hummingbird
import HummingbirdWebSocket

/// Binding the port: the one thing `baguette serve` does that only a real
/// listener can. Everything it serves is `makeRouter()`, tested in-process.
extension Server {

    func run() async throws {
        let router = makeRouter()
        log("listening on \(Self.devicesPage(host: host, port: port))")

        let app = Application(
            router: router,
            // The inbound frame decoder defaults to 16 KB and CLOSES
            // the connection on a bigger frame. Browser traffic never
            // gets near that, but a device-twin companion sends whole
            // encoded video frames as single WS frames — an 888×1920
            // keyframe is a few hundred KB — and the default silently
            // killed the socket after the first one. 8 MB comfortably
            // covers a keyframe at any current device resolution.
            server: .http1WebSocketUpgrade(
                webSocketRouter: router,
                configuration: .init(maxFrameSize: 8 << 20)
            ),
            configuration: .init(address: .hostname(host, port: port))
        )
        try await app.runService()
    }
}
