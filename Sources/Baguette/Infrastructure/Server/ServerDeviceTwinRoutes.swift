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
        let models = self.models

        // The unified page: same sim.html shell as `/simulators/:udid`;
        // the JS switches its base path from the URL.
        router.get("/devices/:udid") { _, _ in Self.staticAsset("sim.html") }

        // Model resolution for the 3D twin. Matched (by hardware id,
        // e.g. "iPhone14,3") → the same shape the simulator route
        // serves. Unmatched → the installed models as choices, because
        // baguette never silently substitutes a look-alike: the user
        // picks, and the pick rides `?model=` on the 3D socket.
        router.get("/devices/:udid/3d-model.json") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let udid = Self.udidParam(r)
            guard let device = devices.find(udid: udid) else {
                return Self.twinJSONResponse(
                    ["ok": false, "error": "no connected device \(udid)"], status: .notFound
                )
            }
            if let installed = try? models.match(hardware: device.model) {
                return Self.twinJSONResponse(
                    Self.model3DJSONObject(definition: installed.definition), status: .ok
                )
            }
            let choices = ((try? models.all()) ?? []).map { installed in
                ["id": installed.definition.id.rawValue,
                 "displayName": installed.definition.displayName]
            }
            return Self.twinJSONResponse(
                ["model": NSNull(), "hardware": device.model, "models": choices],
                status: .ok
            )
        }

        router.ws(
            "/devices/:udid/stream.3d.mjpeg",
            shouldUpgrade: trustedWebSocketUpgrade
        ) { inbound, outbound, context in
            await Self.twinLive3DStreamWS(
                udid: Self.udidParam(context.request), format: .mjpeg,
                query: Self.twinQuery(context.request),
                devices: devices, models: models, screens: screens,
                inbound: inbound, outbound: outbound
            )
        }
        router.ws(
            "/devices/:udid/stream.3d.avcc",
            shouldUpgrade: trustedWebSocketUpgrade
        ) { inbound, outbound, context in
            await Self.twinLive3DStreamWS(
                udid: Self.udidParam(context.request), format: .avcc,
                query: Self.twinQuery(context.request),
                devices: devices, models: models, screens: screens,
                inbound: inbound, outbound: outbound
            )
        }

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
        var chunks = 0
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
                        chunks += 1
                        screens.find(udid: udid)?.ingest(chunk: chunk)
                    }
                }
            }
            log("[device] companion stream ended after \(chunks) chunks")
        } catch {
            log("[device] companion socket errored after \(chunks) chunks: \(error)")
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

    /// The device flavor of `live3DStreamWS`: the same scene, plan,
    /// camera control and `screen_quad` push as the simulator's 3D
    /// socket, with the decoded mirror as the screen source and no
    /// gesture pipe (rejected loudly until the Twin runner lands).
    private static func twinLive3DStreamWS(
        udid: String,
        format: StreamFormat,
        query: [String: [String]],
        devices: LiveDevices,
        models: any DeviceModels,
        screens: TwinScreens,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        guard let device = devices.find(udid: udid),
              let hub = screens.find(udid: udid) else {
            try? await outbound.write(.text(Self.twinErrorFrame("no connected device \(udid)")))
            return
        }
        let options: Device3DStreamOptions
        do {
            options = try Device3DStreamOptions.parse(query)
        } catch {
            try? await outbound.write(.text(Self.twinErrorFrame("invalid live 3D stream options")))
            return
        }

        let installed: InstalledDeviceModel?
        if let pick = options.model {
            installed = try? models.find(id: pick)
        } else {
            installed = try? models.match(hardware: device.model)
        }
        guard let installed else {
            try? await outbound.write(.text(Self.twinErrorFrame(
                "no 3D model for \(device.model) — pick one with ?model="
            )))
            return
        }

        let scene: RealityKitDeviceScene
        do {
            let plan = try DeviceRenderPlan.build(
                model: installed,
                variants: options.variants,
                rotation: options.rotation,
                outputSize: options.outputSize,
                fit: options.fit,
                background: options.background,
                screenGlass: options.screenGlass
            )
            scene = try RealityKitDeviceScene(plan: plan)
        } catch {
            try? await outbound.write(.text(Self.twinErrorFrame(String(describing: error))))
            return
        }

        let sink = WebSocketFrameSink(outbound: outbound, format: format)
        let stream = format.makeStream(config: .default.with(fps: 20), sink: sink, quality: 0.7)
        let screen = RenderedScreen(source: hub.view(), scene: scene)
        do {
            try stream.start(on: screen)
        } catch {
            try? await outbound.write(.text(Self.twinErrorFrame(String(describing: error))))
            return
        }
        defer {
            stream.stop()
        }

        if let quad = scene.screenQuad, let json = Self.screenQuadJSON(quad) {
            try? await outbound.write(.text(json))
        }

        do {
            for try await frame in inbound {
                guard frame.opcode == .text else { continue }
                let line = String(buffer: frame.data)
                do {
                    if try Self.handleLive3DControl(line: line, scene: scene) {
                        screen.refresh()
                        if let quad = scene.screenQuad, let json = Self.screenQuadJSON(quad) {
                            try? await outbound.write(.text(json))
                        }
                        continue
                    }
                } catch {
                    try? await outbound.write(.text(#"{"ok":false,"error":"invalid 3D camera"}"#))
                    continue
                }
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

    private static func twinQuery(_ request: Request) -> [String: [String]] {
        var query: [String: [String]] = [:]
        for pair in request.uri.queryParameters {
            query[String(pair.key), default: []].append(String(pair.value))
        }
        return query
    }

    private static func twinJSONResponse(_ object: [String: Any], status: HTTPResponse.Status) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        return Response(
            status: status,
            headers: [.contentType: "application/json", .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }

    private static func twinErrorFrame(_ reason: String) -> String {
        let payload: [String: Any] = ["ok": false, "error": reason]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]
        ) else { return #"{"error":"unknown","ok":false}"# }
        return String(decoding: data, as: UTF8.self)
    }
}
