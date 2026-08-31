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
/// GET /devices.json                        → connected companions
/// WS  /devices/:udid/companion/video       → that device's video ingest
/// WS  /devices/:udid/companion/motion      → that device's attitude ingest
/// WS  /devices/:udid/stream?format=        → mirror frames to the browser
///
/// The udid is always in the path, like everywhere else in the tree;
/// the hello introduces the device but must agree with the address.
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
        let chromes = self.chromes
        let poses = self.twinPoses

        // The companion's motion socket: hello, then attitude samples
        // at sensor rate. Kept apart from the video socket on purpose —
        // video bursts must never delay 16-byte pose samples.
        router.ws(
            "/devices/:udid/companion/motion",
            shouldUpgrade: trustedWebSocketUpgrade
        ) { inbound, outbound, context in
            // 4 segments — `udidParam`'s second-to-last rule would grab
            // "companion", so the position is explicit.
            let parts = context.request.uri.path.split(separator: "/")
            let pathUdid = parts.count >= 2
                ? String(parts[1]).removingPercentEncoding ?? "" : ""
            var session = TwinSession(expecting: pathUdid)
            var udid: String?
            var lastArrival: TimeInterval?
            var gapMax = 0.0
            var gapSum = 0.0
            var gapCount = 0
            do {
                for try await frame in inbound {
                    guard frame.opcode == .text else { continue }
                    switch session.receive(text: String(buffer: frame.data)) {
                    case .registered(let hello):
                        devices.register(hello: hello)
                        udid = hello.udid
                        try? await outbound.write(.text(#"{"ok":true}"#))
                    case .attitude(let sample):
                        if let udid {
                            poses.update(udid: udid, sample: sample)
                            // Cadence telemetry: smoothness disputes are
                            // settled by arrival gaps, not vibes. One
                            // line every ~5 s of samples.
                            let now = ProcessInfo.processInfo.systemUptime
                            if let last = lastArrival {
                                let gap = now - last
                                gapMax = max(gapMax, gap)
                                gapSum += gap
                                gapCount += 1
                                if gapCount >= 300 {
                                    let mean = gapSum / Double(gapCount) * 1000
                                    log(String(format:
                                        "[device] motion cadence: mean %.1fms, worst %.0fms over %d samples",
                                        mean, gapMax * 1000, gapCount))
                                    gapMax = 0; gapSum = 0; gapCount = 0
                                }
                            }
                            lastArrival = now
                        }
                    case .rejected(let reason):
                        try? await outbound.write(.text(Self.twinErrorFrame(reason)))
                    case .streamOpened, .frame:
                        break
                    }
                }
            } catch {
                // socket closed; cleanup below
            }
            if let udid {
                poses.clear(udid: udid)
                devices.unregister(udid: udid)
                log("[device] motion socket closed: \(udid)")
            }
        }

        // The unified page: same sim.html shell as `/simulators/:udid`;
        // the JS switches its base path from the URL.
        router.get("/devices/:udid") { _, _ in Self.staticAsset("sim.html") }

        // SDK bootstrap for a physical device. A phone has no DeviceKit
        // chrome of its own on this Mac, so the bezel is BORROWED — the
        // user picks a device name (`?chrome=iPhone 17 Pro Max`) and the
        // definition's image URLs carry the pick in their path, keeping
        // the bezel routes stateless. No pick → 404 with `needsChrome`
        // so the page renders the picker instead of a dead end.
        router.get("/devices/:udid/definition.json") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let udid = Self.udidParam(r)
            guard let device = devices.find(udid: udid) else {
                return Self.twinJSONResponse(
                    ["ok": false, "error": "no connected device \(udid)"], status: .notFound
                )
            }
            guard let chromeName = r.uri.queryParameters.get("chrome").map({ String($0) }),
                  !chromeName.isEmpty else {
                return Self.twinJSONResponse(
                    ["ok": false, "needsChrome": true,
                     "error": "pick a chrome with ?chrome=<device name>"],
                    status: .notFound
                )
            }
            guard let assets = chromes.assets(forDeviceName: chromeName) else {
                return Self.twinJSONResponse(
                    ["ok": false, "needsChrome": true,
                     "error": "no chrome named \(chromeName)"],
                    status: .notFound
                )
            }
            let encodedName = chromeName.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed) ?? chromeName
            let definition = SimulatorDefinition.compose(
                identity: SimulatorDefinition.Identity(
                    udid: device.udid, name: device.name, model: device.model
                ),
                chrome: assets,
                urlPrefix: "/devices/\(udid)/chrome/\(encodedName)"
            )
            return Response(
                status: .ok,
                headers: [.contentType: "application/json", .cacheControl: "no-cache"],
                body: .init(byteBuffer: ByteBuffer(string: definition.toJSON()))
            )
        }

        // Borrowed-bezel images. The chrome name sits in the path
        // (`/devices/:udid/chrome/:name/bezel.png`), so `udidParam`'s
        // second-to-last rule doesn't apply — positions are explicit.
        router.get("/devices/:udid/chrome/:name/bezel.png") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let parts = r.uri.path.split(separator: "/")
            let name = parts.count >= 4
                ? String(parts[3]).removingPercentEncoding ?? "" : ""
            let withButtons = r.uri.queryParameters.get("buttons")
                .map { $0.lowercased() != "false" } ?? true
            guard let assets = chromes.assets(forDeviceName: name) else {
                return Self.twinJSONResponse(
                    ["ok": false, "error": "no chrome named \(name)"], status: .notFound
                )
            }
            let bytes = withButtons ? assets.composite.data : assets.bareComposite.data
            return Response(
                status: .ok,
                headers: [.contentType: "image/png", .cacheControl: "public, max-age=86400"],
                body: .init(byteBuffer: ByteBuffer(data: bytes))
            )
        }
        router.get("/devices/:udid/chrome/:name/chrome-button/:file") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let parts = r.uri.path.split(separator: "/")
            let name = parts.count >= 5
                ? String(parts[3]).removingPercentEncoding ?? "" : ""
            var button = String(parts.last ?? "").removingPercentEncoding ?? ""
            if button.hasSuffix(".png") { button = String(button.dropLast(4)) }
            guard let assets = chromes.assets(forDeviceName: name),
                  let image = assets.buttonImages[button] else {
                return Self.twinJSONResponse(
                    ["ok": false, "error": "no button \(button) for \(name)"], status: .notFound
                )
            }
            return Response(
                status: .ok,
                headers: [.contentType: "image/png", .cacheControl: "public, max-age=86400"],
                body: .init(byteBuffer: ByteBuffer(data: image.data))
            )
        }

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
                devices: devices, models: models, screens: screens, poses: poses,
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
                devices: devices, models: models, screens: screens, poses: poses,
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
            "/devices/:udid/companion/video",
            shouldUpgrade: trustedWebSocketUpgrade
        ) { inbound, outbound, context in
            let parts = context.request.uri.path.split(separator: "/")
            let pathUdid = parts.count >= 2
                ? String(parts[1]).removingPercentEncoding ?? "" : ""
            await Self.twinVideoWS(
                expecting: pathUdid,
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
        expecting pathUdid: String,
        devices: LiveDevices,
        screens: TwinScreens,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        var session = TwinSession(expecting: pathUdid)
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
        poses: TwinPoses,
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
        // Format-aware pacing, unlike the simulator's 3D stage at 20:
        // the gyro repositions the model continuously, so the pose
        // clock below ticks at the STREAM's fps — one pacing authority,
        // and a `set_fps` from the browser retunes both together. The
        // connect default respects what the format can afford: AVCC
        // deltas are cheap at 60; MJPEG re-sends a full JPEG per frame,
        // and a plain-HTTP LAN origin has no WebCodecs (issue #71) so
        // MJPEG is exactly what those browsers are forced onto — 30 is
        // its honest ceiling.
        let defaultFPS = format == .avcc ? 60 : 30
        let stream = format.makeStream(
            config: .default.with(fps: defaultFPS), sink: sink, quality: 0.7
        )
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

        // The gyro: attitude samples drive the model pose. The first
        // sample auto-zeroes (the twin faces front from wherever the
        // phone happens to be); `{"type":"rezero"}` re-captures that
        // reference. Applies are throttled to ~20/s and the projected
        // screen quad is re-pushed a few times a second so Interact
        // clicks stay pose-accurate while the phone moves.
        let gyro = TwinGyroState(zoom: 1)
        // The gyro paces to the connect-time fps; `set_fps` retunes the
        // encoder live but the pose cadence keeps this bound (the
        // stream's own pacing still drops anything above its rate).
        let paceFPS = defaultFPS
        let subscriberID = UUID().uuidString
        poses.subscribe(udid: udid, id: subscriberID) { sample in
            // Samples only feed the trajectory buffer; the metronome
            // below is what poses the scene, so ReplayKit's irregular
            // arrivals never set the render cadence.
            if gyro.add(sample, arrivedAt: ProcessInfo.processInfo.systemUptime) {
                Task { try? await outbound.write(.text(#"{"type":"gyro","live":true}"#)) }
            }
        }
        // The metronome — the server-side equivalent of the 60 fps
        // render loop a client-side twin gets for free. Video is only
        // smooth when its frames sample motion at REGULAR times, so
        // the tick runs at the stream's fps and replays the buffered
        // trajectory (see `TwinGyroState`); a tick with nothing new
        // costs nothing and a resting phone emits zero pose frames.
        let ticker = Task {
            while !Task.isCancelled {
                if let applied = gyro.pose(at: ProcessInfo.processInfo.systemUptime) {
                    scene.update(pose: applied.attitude, zoom: applied.zoom)
                    screen.refresh()
                    if applied.pushQuad, let quad = scene.screenQuad,
                       let json = Self.screenQuadJSON(quad) {
                        try? await outbound.write(.text(json))
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / paceFPS))
            }
        }
        defer {
            ticker.cancel()
            poses.unsubscribe(udid: udid, id: subscriberID)
        }

        do {
            for try await frame in inbound {
                guard frame.opcode == .text else { continue }
                let line = String(buffer: frame.data)
                if line.contains("\"rezero\"") {
                    gyro.rezero()
                    continue
                }
                do {
                    if try Self.handleLive3DControl(line: line, scene: scene) {
                        if let data = line.data(using: .utf8),
                           let camera = try? Device3DCamera.parsing(json: data) {
                            gyro.set(zoom: camera.zoom)
                        }
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
