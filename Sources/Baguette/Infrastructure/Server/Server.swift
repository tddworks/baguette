import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore
@_spi(WSInternal) import WSCore

/// Standalone HTTP + WebSocket server for `baguette serve`.
///
/// The server is **dumb**: it serves static UI files unchanged and
/// projects domain values to JSON / PNG. No HTML rewriting, no
/// template extraction, no script inlining. Anything UI-shaped lives
/// in `Resources/Web/` and is the front-end's problem.
///
/// Canonical routes (no `/api/` prefix; UDID always in path; format
/// distinguished by file extension):
///
///   GET  /                                  → 302 → /simulators
///   GET  /simulators                        → sim.html
///   GET  /simulators.json                   → list JSON
///   GET  /simulators/:udid                  → sim.html  (stream)
///   POST /simulators/:udid/boot             → simulator.boot()
///   POST /simulators/:udid/shutdown         → simulator.shutdown()
///   GET  /simulators/:udid/chrome.json      → chrome layout JSON
///   GET  /simulators/:udid/bezel.png        → composite PNG
///   POST /simulators/:udid/input            → gesture     (TODO)
///   GET  /simulators/:udid/screenshot.jpg   → JPEG        (TODO)
///   WS   /simulators/:udid/stream?format=   → frames      (TODO)
///   GET  /<file>.{html,js,css}              → static UI asset
///
/// Static UI siblings live at the *root* (e.g. `GET /sim-list.js`)
/// so the page at `/simulators` resolves `<script src="sim-list.js">`
/// to a sibling — no prefix juggling, no conflict with the
/// `/simulators/:udid` resource tree (UDIDs don't end in `.js`).
struct Server: Sendable {
    let simulators: any Simulators
    let chromes: any Chromes
    let host: String
    let port: Int

    init(
        simulators: any Simulators,
        chromes: any Chromes,
        host: String = "127.0.0.1",
        port: Int = 8421
    ) {
        self.simulators = simulators
        self.chromes = chromes
        self.host = host
        self.port = port
    }

    func run() async throws {
        let router = makeRouter()
        log("listening on http://\(host):\(port)/simulators")

        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname(host, port: port))
        )
        try await app.runService()
    }

    /// Exposed for tests — build the router without binding a port.
    func makeRouter() -> Router<BasicWebSocketRequestContext> {
        let router = Router(context: BasicWebSocketRequestContext.self)
        registerRoutes(on: router)
        return router
    }

    // MARK: - routes

    private func registerRoutes(on router: Router<BasicWebSocketRequestContext>) {
        // List page (HTML + sibling assets).
        router.get("/") { _, _ in Self.redirect(to: "/simulators") }
        router.get("/simulators") { _, _ in Self.staticAsset("sim.html") }
        router.get("/simulators.json") { [simulators] _, _ in Self.listJSON(simulators) }

        // Stream page — same sim.html, JS routes the inner view based on URL.
        router.get("/simulators/:udid") { _, _ in Self.staticAsset("sim.html") }

        // Simulator actions.
        router.post("/simulators/:udid/boot")     { [simulators] r, _ in
            Self.lifecycle(udid: Self.udidParam(r), simulators: simulators) { try $0.boot() }
        }
        router.post("/simulators/:udid/shutdown") { [simulators] r, _ in
            Self.lifecycle(udid: Self.udidParam(r), simulators: simulators) { try $0.shutdown() }
        }

        // Chrome / bezel — DeviceKit-sourced layout + rasterized PNG.
        router.get("/simulators/:udid/chrome.json") { [simulators, chromes] r, _ in
            Self.chromeJSON(udid: Self.udidParam(r), simulators: simulators, chromes: chromes)
        }
        router.get("/simulators/:udid/bezel.png") { [simulators, chromes] r, _ in
            Self.bezelPNG(udid: Self.udidParam(r), simulators: simulators, chromes: chromes)
        }

        // Finished MP4 recordings — `start_record` / `stop_record` over
        // the live WS produce a file under `RecordingsDirectory.root`,
        // and the WS sends back a `{type:"record_finished", filename}`
        // text frame whose filename resolves here.
        router.get("/simulators/:udid/recording/:filename") { r, _ in
            Self.recordingFile(
                udid: Self.udidParamAt(r, fromEnd: 3),
                filename: Self.lastPathSegment(r)
            )
        }

        // Device-farm UI — multi-device dashboard. The HTML at /farm
        // is a thin shell that loads its own component scripts from
        // the `farm/` subfolder; sibling assets (CSS + per-component
        // JS) resolve against `/farm/<file>`. Registered before the
        // catch-all `/:file` so `/farm` doesn't get hijacked.
        router.get("/farm") { _, _ in Self.staticAsset("farm/farm.html") }
        router.get("/farm/:file") { r, _ in
            let name = String(r.uri.path.split(separator: "/").last ?? "")
                .removingPercentEncoding ?? ""
            return Self.staticAsset("farm/\(name)")
        }

        // Live stream — encoded frames downstream as binary; upstream
        // text JSON carries everything else: gesture input + runtime
        // control (set_bitrate / set_fps / set_scale / force_idr /
        // snapshot). One bidirectional channel per session means no
        // POST /event side-route, no UDID-keyed registry — the WS
        // closure already owns the live stream + sim handles.
        router.ws("/simulators/:udid/stream") { [simulators] inbound, outbound, context in
            await Self.streamWS(
                udid: Self.udidParam(context.request),
                format: context.request.uri.queryParameters.get("format")
                    .flatMap { StreamFormat(rawValue: $0) } ?? .mjpeg,
                simulators: simulators,
                inbound: inbound,
                outbound: outbound
            )
        }

        // Static UI siblings — JS / HTML / CSS files in Resources/Web/
        // accessed by name. Path component is the bare filename.
        router.get("/:file") { r, _ in
            let name = String(r.uri.path.split(separator: "/").last ?? "")
                .removingPercentEncoding ?? ""
            return Self.staticAsset(name)
        }
    }

    // MARK: - handlers

    private static func staticAsset(_ name: String) -> Response {
        guard let data = WebRoot.data(named: name) else {
            return Response(
                status: .notFound,
                headers: [.contentType: "text/plain; charset=utf-8"],
                body: .init(byteBuffer: ByteBuffer(string:
                    "missing \(name) — set BAGUETTE_WEB_DIR or rebuild"
                ))
            )
        }
        return Response(
            status: .ok,
            headers: [.contentType: contentType(for: name), .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }

    private static func listJSON(_ simulators: any Simulators) -> Response {
        Response(
            status: .ok,
            headers: [.contentType: "application/json", .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(string: simulators.listJSON))
        )
    }

    private static func lifecycle(
        udid: String,
        simulators: any Simulators,
        action: (Simulator) throws -> Void
    ) -> Response {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            return errorJSON("unknown udid: \(udid)", status: .notFound)
        }
        do {
            try action(sim)
            return jsonOK
        } catch {
            return errorJSON(String(describing: error), status: .internalServerError)
        }
    }

    private static func chromeJSON(
        udid: String,
        simulators: any Simulators,
        chromes: any Chromes
    ) -> Response {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid),
              let assets = sim.chrome(in: chromes) else {
            return errorJSON("no chrome for udid \(udid)", status: .notFound)
        }
        return Response(
            status: .ok,
            headers: [.contentType: "application/json", .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(string: assets.layoutJSON()))
        )
    }

    private static func bezelPNG(
        udid: String,
        simulators: any Simulators,
        chromes: any Chromes
    ) -> Response {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid),
              let assets = sim.chrome(in: chromes) else {
            return Response(
                status: .notFound,
                headers: [.contentType: "text/plain"],
                body: .init(byteBuffer: ByteBuffer(string: "no bezel for \(udid)"))
            )
        }
        return Response(
            status: .ok,
            headers: [.contentType: "image/png", .cacheControl: "public, max-age=86400"],
            body: .init(byteBuffer: ByteBuffer(data: assets.composite.data))
        )
    }

    /// One WebSocket = one streaming session. Opens Screen + Stream
    /// + WS sink, runs until the client disconnects. Every inbound
    /// text frame is one JSON line dispatched in this order:
    ///   1. ReconfigParser   — set_bitrate / set_fps / set_scale
    ///   2. RecordingControl — start_record / stop_record (avcc only)
    ///   3. stream verbs     — force_idr / snapshot
    ///   4. GestureDispatcher — tap / swipe / touch1-* / touch2-* /
    ///      button / scroll / pinch / pan / key / type
    /// Lines not matched by any of the above are ignored — same
    /// graceful behaviour the stdin control channel has.
    private static func streamWS(
        udid: String,
        format: StreamFormat,
        simulators: any Simulators,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            try? await outbound.write(.text(#"{"ok":false,"error":"unknown udid"}"#))
            return
        }

        let sink = WebSocketFrameSink(outbound: outbound, format: format)
        let stream = format.makeStream(config: .default, sink: sink, quality: 0.5)
        let screen = sim.screen()
        let dispatcher = GestureDispatcher(input: sim.input())
        // Per-session recorder slot. The lifetime is exactly the inbound
        // loop — start_record sets it, stop_record clears it, and the
        // defer below cancels any leftover when the WS closes.
        var recorder: FFmpegRecorder?

        do {
            try stream.start(on: screen)
        } catch {
            try? await outbound.write(.text(
                #"{"ok":false,"error":"\#(String(describing: error))"}"#
            ))
            return
        }
        defer {
            recorder?.cancel()
            (stream as? RecordableStream)?.detachRecorder()
            stream.stop()
            screen.stop()
        }

        do {
            for try await frame in inbound {
                guard frame.opcode == .text else { continue }
                let line = String(buffer: frame.data)
                if let cmd = RecordingControl.parse(line) {
                    await handleRecording(
                        cmd, udid: udid, stream: stream,
                        recorder: &recorder, outbound: outbound
                    )
                    continue
                }
                handleInbound(line: line, stream: stream, dispatcher: dispatcher)
            }
        } catch {
            // socket closed; defer cleans up
        }
    }

    /// Triage one upstream text line: stream config first (cheapest
    /// to detect), then format-level verbs, then gesture dispatch as
    /// the catch-all. ReconfigParser returns the same config when
    /// the line wasn't a `set_*` — that's our discriminator.
    private static func handleInbound(
        line: String,
        stream: any Stream,
        dispatcher: GestureDispatcher
    ) {
        let next = ReconfigParser.apply(line, to: stream.config)
        if next != stream.config {
            stream.apply(next)
            return
        }
        if let data = line.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let kind = dict["type"] as? String {
            switch kind {
            case "force_idr": stream.requestKeyframe(); return
            case "snapshot":  stream.requestSnapshot(); return
            default: break
            }
        }
        _ = dispatcher.dispatch(line: line)
    }

    /// Apply a recording verb. Recording is only wired into AVCC
    /// streams (the only format whose encoder produces H.264 NALUs we
    /// can copy into MP4 without a re-encode). For MJPEG, the start
    /// verb is rejected with a `record_error` text frame so the UI
    /// can surface it. Stop on a not-recording session is a no-op —
    /// idempotent, so a stale toggle in the browser is harmless.
    private static func handleRecording(
        _ cmd: RecordingControl,
        udid: String,
        stream: any Stream,
        recorder: inout FFmpegRecorder?,
        outbound: WebSocketOutboundWriter
    ) async {
        switch cmd {
        case .start:
            guard recorder == nil else { return }
            guard let recordable = stream as? RecordableStream else {
                try? await outbound.write(.text(
                    #"{"type":"record_error","error":"recording requires avcc format"}"#
                ))
                return
            }
            let url = RecordingsDirectory.newOutputURL(udid: udid, format: .mp4)
            let r = FFmpegRecorder(outputURL: url)
            recordable.attach(recorder: r)
            recorder = r
            try? await outbound.write(.text(#"{"type":"record_started"}"#))

        case .stop:
            guard let r = recorder else { return }
            (stream as? RecordableStream)?.detachRecorder()
            recorder = nil
            do {
                let artifact = try r.finish()
                let payload = recordingFinishedJSON(udid: udid, artifact: artifact)
                try? await outbound.write(.text(payload))
            } catch {
                let escaped = String(describing: error)
                    .replacingOccurrences(of: "\"", with: "\\\"")
                try? await outbound.write(.text(
                    #"{"type":"record_error","error":"\#(escaped)"}"#
                ))
            }
        }
    }

    /// Build the JSON the browser receives after a successful recording
    /// stop. The download URL is reachable via the
    /// `/simulators/:udid/recording/:filename` route registered above.
    private static func recordingFinishedJSON(
        udid: String, artifact: RecordingArtifact
    ) -> String {
        var payload: [String: Any] = artifact.dictionary
        payload["type"] = "record_finished"
        payload["url"] = "/simulators/\(udid)/recording/\(artifact.filename)"
        let data = try! JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// Serve a finished MP4 recording. The route's path shape is
    /// `/simulators/<udid>/recording/<filename>`, so the request URL has
    /// 4 segments after the leading slash. RecordingsDirectory enforces
    /// the file lives inside the per-udid subtree — no path traversal.
    private static func recordingFile(udid: String, filename: String) -> Response {
        guard let url = RecordingsDirectory.resolve(udid: udid, filename: filename),
              let data = try? Data(contentsOf: url) else {
            return Response(
                status: .notFound,
                headers: [.contentType: "text/plain; charset=utf-8"],
                body: .init(byteBuffer: ByteBuffer(string: "recording not found"))
            )
        }
        let contentType: String = filename.hasSuffix(".mp4")
            ? "video/mp4" : "application/octet-stream"
        return Response(
            status: .ok,
            headers: [
                .contentType: contentType,
                .cacheControl: "no-cache",
                .contentDisposition: "attachment; filename=\"\(filename)\"",
            ],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }

    /// Pull the UDID out of a `/simulators/<udid>/<verb>` request.
    /// `<verb>` is the last segment, `<udid>` the one before.
    private static func udidParam(_ request: Request) -> String {
        let parts = request.uri.path.split(separator: "/")
        guard parts.count >= 3 else { return "" }
        return String(parts[parts.count - 2]).removingPercentEncoding ?? ""
    }

    /// Pull a path segment counted from the right, used by routes
    /// deeper than `/simulators/:udid/:verb`. For
    /// `/simulators/<udid>/recording/<file>`, the udid is at fromEnd=3.
    private static func udidParamAt(_ request: Request, fromEnd: Int) -> String {
        let parts = request.uri.path.split(separator: "/")
        guard parts.count >= fromEnd, fromEnd >= 1 else { return "" }
        return String(parts[parts.count - fromEnd]).removingPercentEncoding ?? ""
    }

    /// The trailing path segment — the bare filename for recording
    /// downloads and static assets.
    private static func lastPathSegment(_ request: Request) -> String {
        String(request.uri.path.split(separator: "/").last ?? "")
            .removingPercentEncoding ?? ""
    }


    private static func redirect(to path: String) -> Response {
        Response(
            status: .found,
            headers: [.location: path],
            body: .init(byteBuffer: ByteBuffer(string: ""))
        )
    }
}

// MARK: - tiny response helpers

private let jsonOK = Response(
    status: .ok,
    headers: [.contentType: "application/json"],
    body: .init(byteBuffer: ByteBuffer(string: "{\"ok\":true}"))
)

private func errorJSON(_ message: String, status: HTTPResponse.Status) -> Response {
    let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
    return Response(
        status: status,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(string:
            "{\"ok\":false,\"error\":\"\(escaped)\"}"
        ))
    )
}

private func contentType(for filename: String) -> String {
    if filename.hasSuffix(".html") { return "text/html; charset=utf-8" }
    if filename.hasSuffix(".js")   { return "application/javascript; charset=utf-8" }
    if filename.hasSuffix(".css")  { return "text/css; charset=utf-8" }
    if filename.hasSuffix(".json") { return "application/json; charset=utf-8" }
    if filename.hasSuffix(".png")  { return "image/png" }
    if filename.hasSuffix(".jpg") || filename.hasSuffix(".jpeg") { return "image/jpeg" }
    return "application/octet-stream"
}
