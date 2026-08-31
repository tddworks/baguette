import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// Device-twin routes — the physical-device sibling of the
/// `/simulators` tree. Kept out of `Server.swift`'s main body for the
/// same reason the logs, interface, and plugin routes are: that file's
/// router-builder inference grinds once too many closures share one
/// function.
///
/// ```text
/// GET /devices.json               → connected companions
/// WS  /devices/companion/video    → the companion app's video socket
/// WS  /devices/:udid/stream?format= → mirror frames to the browser
/// ```
extension Server {
    func registerDeviceTwinRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?,
        trustedWebSocketUpgrade: @escaping @Sendable (Request, BasicWebSocketRequestContext)
            async throws -> RouterShouldUpgrade
    ) {
        let devices = self.devices
        let screens = self.twinScreens

        router.get("/devices.json") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            return Response(
                status: .ok,
                headers: [.contentType: "application/json", .cacheControl: "no-cache"],
                body: .init(byteBuffer: ByteBuffer(string: devices.listJSON))
            )
        }

        // The companion app's video socket: hello → format → binary
        // AVCC chunks. `TwinSession` owns the protocol; this closure
        // only moves bytes and applies the events.
        router.ws(
            "/devices/companion/video",
            shouldUpgrade: trustedWebSocketUpgrade
        ) { inbound, outbound, _ in
            await Self.twinVideoWS(
                devices: devices, screens: screens,
                inbound: inbound, outbound: outbound
            )
        }

        // Browser-facing mirror stream — the same bidirectional shape
        // as `/simulators/:udid/stream`: encoded frames downstream,
        // JSON control lines upstream. Gestures are rejected loudly
        // until the control pipe (the Twin runner) lands.
        // `/devices/…` is a resource root like `/simulators/…` — the
        // web-asset folder that used to sit at this URL is served from
        // `/sim-list/` so the wildcard position stays free (Hummingbird
        // fatals when two routes disagree on a param name at the same
        // position).
        router.ws(
            "/devices/:udid/stream",
            shouldUpgrade: trustedWebSocketUpgrade
        ) { inbound, outbound, context in
            await Self.twinStreamWS(
                udid: Self.udidParam(context.request),
                format: context.request.uri.queryParameters.get("format")
                    .flatMap { StreamFormat(rawValue: $0) } ?? .mjpeg,
                screens: screens,
                inbound: inbound,
                outbound: outbound
            )
        }
    }

    private static func twinVideoWS(
        devices: LiveDevices,
        screens: TwinScreens,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        var session = TwinSession()
        var udid: String?
        log("[device] companion video socket opened")
        do {
            // Messages, not frames: a video chunk may arrive fragmented
            // and must be reassembled before `AVCCEnvelope.unwrap` sees it.
            for try await message in inbound.messages(maxSize: 8 << 20) {
                switch message {
                case .text(let line):
                    switch session.receive(text: line) {
                    case .registered(let hello):
                        devices.register(hello: hello)
                        udid = hello.udid
                        _ = screens.open(udid: hello.udid)
                        try? await outbound.write(.text(#"{"ok":true}"#))
                    case .streamOpened(let format):
                        log("[device] video stream opened: \(format.width)×\(format.height) \(format.codec)")
                    case .rejected(let reason):
                        try? await outbound.write(.text(Self.twinErrorFrame(reason)))
                    case .attitude, .frame:
                        break
                    }
                case .binary(let buffer):
                    if case .frame(let chunk) = session.receive(binary: Data(buffer: buffer)),
                       let udid {
                        screens.find(udid: udid)?.ingest(chunk: chunk)
                    }
                }
            }
        } catch {
            // socket closed; cleanup below
        }
        if let udid {
            screens.close(udid: udid)
            devices.unregister(udid: udid)
        }
    }

    private static func twinStreamWS(
        udid: String,
        format: StreamFormat,
        screens: TwinScreens,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        guard !udid.isEmpty, let hub = screens.find(udid: udid) else {
            try? await outbound.write(.text(Self.twinErrorFrame("no connected device \(udid)")))
            return
        }

        let sink = WebSocketFrameSink(outbound: outbound, format: format)
        let stream = format.makeStream(config: .default, sink: sink, quality: 0.5)
        let screen = hub.view()
        do {
            try stream.start(on: screen)
        } catch {
            try? await outbound.write(.text(Self.twinErrorFrame(String(describing: error))))
            return
        }
        defer {
            stream.stop()
            screen.stop()
        }

        do {
            for try await frame in inbound {
                guard frame.opcode == .text else { continue }
                let line = String(buffer: frame.data)
                if !Self.handleTwinInbound(line: line, stream: stream) {
                    try? await outbound.write(.text(
                        Self.twinErrorFrame("device control is not wired yet")
                    ))
                }
            }
        } catch {
            // socket closed; defer cleans up
        }
    }

    /// The stream-control subset of `handleInbound` — reconfig,
    /// `force_idr`, `snapshot`. Returns `false` for anything else
    /// (gestures included) so the caller can reject it loudly instead
    /// of silently dropping input on a surface that cannot act on it.
    private static func handleTwinInbound(line: String, stream: any Stream) -> Bool {
        let next = ReconfigParser.apply(line, to: stream.config)
        if next != stream.config {
            stream.apply(next)
            return true
        }
        guard let data = line.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = dict["type"] as? String else {
            return false
        }
        switch kind {
        case "force_idr": stream.requestKeyframe(); return true
        case "snapshot":  stream.requestSnapshot(); return true
        default:          return false
        }
    }

    private static func twinErrorFrame(_ reason: String) -> String {
        let payload: [String: Any] = ["ok": false, "error": reason]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]
        ) else { return #"{"error":"unknown","ok":false}"# }
        return String(decoding: data, as: UTF8.self)
    }
}
