import Foundation
import HTTPTypes
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
///   GET  /simulators/:udid/screenshot.jpg   → JPEG (?quality=&scale=)
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
        let bindHost = self.host
        let bindPort = self.port
        let rejectUntrustedBrowser: @Sendable (Request) -> Response? = { request in
            Self.rejectUntrustedBrowserRequest(
                request, bindHost: bindHost, bindPort: bindPort
            )
        }
        let trustedWebSocketUpgrade:
            @Sendable (Request, BasicWebSocketRequestContext) async throws -> RouterShouldUpgrade = {
                request, _ in
                Self.isTrustedBrowserRequest(
                    request, bindHost: bindHost, bindPort: bindPort
                ) ? .upgrade([:]) : .dontUpgrade
            }

        // List page (HTML + sibling assets).
        router.get("/") { _, _ in Self.redirect(to: "/simulators") }
        router.get("/simulators") { _, _ in Self.staticAsset("sim.html") }
        router.get("/simulators.json") { [simulators] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            return Self.listJSON(simulators)
        }

        // Stream page — same sim.html, JS routes the inner view based on URL.
        router.get("/simulators/:udid") { _, _ in Self.staticAsset("sim.html") }

        // Simulator actions.
        router.post("/simulators/:udid/boot")     { [simulators] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            return Self.lifecycle(udid: Self.udidParam(r), simulators: simulators) { try $0.boot() }
        }
        router.post("/simulators/:udid/shutdown") { [simulators] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            return Self.lifecycle(udid: Self.udidParam(r), simulators: simulators) { try $0.shutdown() }
        }
        // Orientation — `?value=portrait|landscape-left|landscape-right|portrait-upside-down`.
        // Routes through `simulator.orientation().set(...)` which fires
        // a GSEvent over `PurpleWorkspacePort`. Pure parse + dispatch
        // logic lives in `Server.applyOrientation` for unit testing.
        router.post("/simulators/:udid/orientation") { [simulators] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let value = r.uri.queryParameters.get("value") ?? ""
            switch Self.applyOrientation(
                udid: Self.udidParam(r), value: value, simulators: simulators
            ) {
            case .ok:
                return jsonOK
            case .invalidValue:
                return errorJSON(
                    "value must be one of portrait, landscape-left, landscape-right, portrait-upside-down",
                    status: .badRequest
                )
            case .unknownDevice:
                return errorJSON("unknown udid: \(Self.udidParam(r))", status: .notFound)
            case .dispatchFailed:
                return errorJSON(
                    "orientation change failed (PurpleWorkspacePort unreachable?)",
                    status: .internalServerError
                )
            }
        }

        // Status bar — `POST` sets overrides from a JSON body,
        // `DELETE` clears them. Backed by `simctl status_bar`; pure
        // parse + dispatch lives in `Server.applyStatusBar` /
        // `clearStatusBar` for unit testing. DELETE (rather than a
        // deeper `/clear` path) keeps the udid second-to-last so
        // `udidParam` extracts it uniformly.
        router.post("/simulators/:udid/status-bar") { [simulators] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let buffer = try? await r.body.collect(upTo: 64 * 1024)
            let body = buffer.map { String(buffer: $0) } ?? ""
            switch await Self.applyStatusBar(
                udid: Self.udidParam(r), body: body, simulators: simulators
            ) {
            case .ok:
                return jsonOK
            case .invalidBody:
                return errorJSON("status-bar body must be a JSON object of valid override fields", status: .badRequest)
            case .emptyOverride:
                return errorJSON("set at least one status-bar field", status: .badRequest)
            case .unknownDevice:
                return errorJSON("unknown udid: \(Self.udidParam(r))", status: .notFound)
            case .dispatchFailed:
                return errorJSON("status-bar override failed (simctl error)", status: .internalServerError)
            }
        }
        // Read current overrides so the browser panel hydrates its
        // controls from the device instead of guessing. Pure parse +
        // dispatch in `Server.readStatusBar`.
        router.get("/simulators/:udid/status-bar") { [simulators] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            switch await Self.readStatusBar(udid: Self.udidParam(r), simulators: simulators) {
            case .ok(let override):
                return Response(
                    status: .ok,
                    headers: [.contentType: "application/json", .cacheControl: "no-cache"],
                    body: .init(byteBuffer: ByteBuffer(string: override.jsonString))
                )
            case .unknownDevice:
                return errorJSON("unknown udid: \(Self.udidParam(r))", status: .notFound)
            case .failed:
                return errorJSON("status-bar read failed (simctl error)", status: .internalServerError)
            }
        }
        router.delete("/simulators/:udid/status-bar") { [simulators] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            switch await Self.clearStatusBar(udid: Self.udidParam(r), simulators: simulators) {
            case .ok:
                return jsonOK
            case .unknownDevice:
                return errorJSON("unknown udid: \(Self.udidParam(r))", status: .notFound)
            case .dispatchFailed:
                return errorJSON("status-bar clear failed (simctl error)", status: .internalServerError)
            case .invalidBody, .emptyOverride:
                return jsonOK // unreachable for clear; keep the switch total
            }
        }

        // Chrome / bezel — DeviceKit-sourced layout + rasterized PNG.
        router.get("/simulators/:udid/chrome.json") { [simulators, chromes] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            return Self.chromeJSON(udid: Self.udidParam(r), simulators: simulators, chromes: chromes)
        }
        // SDK bootstrap — the single endpoint `Baguette.use(udid)` hits
        // to instantiate the JS-side `Simulator` facade. Strict superset
        // of `chrome.json` (which stays for migration); once every
        // page consumes the SDK this route becomes the only chrome read.
        router.get("/simulators/:udid/definition.json") { [simulators, chromes] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            return Self.definitionJSON(udid: Self.udidParam(r), simulators: simulators, chromes: chromes)
        }
        router.get("/simulators/:udid/bezel.png") { [simulators, chromes] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            // ?buttons=false → bare device body (no buttons baked in).
            // The actionable-bezel front end layers per-button images on
            // top via the /chrome-button/<name>.png route below.
            // Default (true) preserves today's merged composite.
            let withButtons = r.uri.queryParameters.get("buttons")
                .map { $0.lowercased() != "false" } ?? true
            return Self.bezelPNG(
                udid: Self.udidParam(r),
                simulators: simulators,
                chromes: chromes,
                withButtons: withButtons
            )
        }
        // Per-button rasterized PNG — feeds the actionable-bezel UI.
        // `:file` is the last URL segment, typically `<name>.png`
        // matching a `ChromeButton.name` in `chrome.json` (e.g.
        // `powerButton.png`, `actionButton.png`, `volumeUp.png`).
        // Registered before the catch-all `/:file` so the longer
        // template wins.
        //
        // UDID extraction here uses positional indexing on the path
        // (`parts[1]`) instead of `udidParam` — that helper assumes
        // a 3-segment path and grabs the second-to-last component,
        // which breaks for this 4-segment template.
        router.get("/simulators/:udid/chrome-button/:file") { [simulators, chromes] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let parts = r.uri.path.split(separator: "/")
            let udid = parts.count >= 4
                ? String(parts[1]).removingPercentEncoding ?? ""
                : ""
            let last = String(parts.last ?? "")
                .removingPercentEncoding ?? ""
            return Self.chromeButtonPNG(
                udid: udid,
                buttonFile: last,
                simulators: simulators,
                chromes: chromes
            )
        }

        // One-shot JPEG of the current framebuffer. Spins up Screen,
        // awaits one IOSurface, encodes, and tears down — `?quality=`
        // and `?scale=` mirror the WS stream knobs for parity.
        router.get("/simulators/:udid/screenshot.jpg") { [simulators] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            return await Self.screenshotJPEG(
                udid: Self.udidParam(r),
                quality: r.uri.queryParameters.get("quality").flatMap(Double.init) ?? 0.85,
                scale: r.uri.queryParameters.get("scale").flatMap(Int.init) ?? 1,
                simulators: simulators
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

        // Baguette SDK — served from `Resources/Web/baguette/`. The
        // SDK's two-level layout (`parts/`, `gestures/`) needs literal
        // subdirectory routes; Hummingbird's router rejects two
        // placeholder routes that share a path slot with different
        // param names (`/baguette/:file` vs `/baguette/:dir/:file`
        // both bind position 2 but disagree on the name), so we
        // register one route per known subdirectory instead.
        router.get("/baguette/:file") { r, _ in
            let name = String(r.uri.path.split(separator: "/").last ?? "")
                .removingPercentEncoding ?? ""
            return Self.staticAsset("baguette/\(name)")
        }
        router.get("/baguette/parts/:file") { r, _ in
            let name = String(r.uri.path.split(separator: "/").last ?? "")
                .removingPercentEncoding ?? ""
            return Self.staticAsset("baguette/parts/\(name)")
        }
        router.get("/baguette/gestures/:file") { r, _ in
            let name = String(r.uri.path.split(separator: "/").last ?? "")
                .removingPercentEncoding ?? ""
            return Self.staticAsset("baguette/gestures/\(name)")
        }

        // Live stream — encoded frames downstream as binary; upstream
        // text JSON carries everything else: gesture input + runtime
        // control (set_bitrate / set_fps / set_scale / force_idr /
        // snapshot). One bidirectional channel per session means no
        // POST /event side-route, no UDID-keyed registry — the WS
        // closure already owns the live stream + sim handles.
        router.ws(
            "/simulators/:udid/stream",
            shouldUpgrade: trustedWebSocketUpgrade
        ) { [simulators] inbound, outbound, context in
            await Self.streamWS(
                udid: Self.udidParam(context.request),
                format: context.request.uri.queryParameters.get("format")
                    .flatMap { StreamFormat(rawValue: $0) } ?? .mjpeg,
                simulators: simulators,
                inbound: inbound,
                outbound: outbound
            )
        }

        // Live unified-log feed — dedicated socket so logs don't
        // share lifetime / backpressure with the frame stream.
        // Filter is fixed at connect time (query string); restart
        // the socket to change the filter. Closing the socket from
        // the client tears down the spawned `log` child.
        registerLogsRoute(on: router)

        // Virtual-camera control + frame production. The browser
        // owns the device picker; baguette enumerates Mac cameras,
        // pumps BGRA frames into the shared-memory ring buffer that
        // VirtualCamera.dylib reads inside the simulator. One WS per
        // sim; closing the socket stops capture but leaves the dylib
        // armed on the sim's launchd domain.
        registerCameraRoute(on: router)

        // Static UI siblings — JS / HTML / CSS files in Resources/Web/
        // accessed by name. Path component is the bare filename.
        router.get("/:file") { r, _ in
            let name = String(r.uri.path.split(separator: "/").last ?? "")
                .removingPercentEncoding ?? ""
            return Self.staticAsset(name)
        }
    }

    // MARK: - handlers

    static func staticAsset(_ name: String) -> Response {
        guard let data = WebRoot.data(named: name) else {
            return Response(
                status: .notFound,
                headers: [
                    .contentType: "text/plain; charset=utf-8",
                    .contentSecurityPolicy: "frame-ancestors 'none'",
                ],
                body: .init(byteBuffer: ByteBuffer(string:
                    "missing \(name) — set BAGUETTE_WEB_DIR or rebuild"
                ))
            )
        }
        return Response(
            status: .ok,
            headers: [
                .contentType: contentType(for: name),
                .cacheControl: "no-cache",
                .contentSecurityPolicy: "frame-ancestors 'none'",
            ],
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

    /// Outcome of `applyOrientation` — one case per HTTP-status
    /// branch the orientation route maps to. Lives next to the
    /// helper so the route closure in `addRoutes(...)` is just a
    /// `switch outcome → Response` translation.
    enum OrientationOutcome: Equatable {
        case ok
        case invalidValue
        case unknownDevice
        case dispatchFailed
    }

    /// Pure parse + dispatch: validate `value`, look up the
    /// simulator, and run `simulator.orientation().set(...)`. Split
    /// out from the route closure so unit tests can drive every
    /// branch (`MockSimulators` + `MockOrientation`) without booting
    /// Hummingbird.
    static func applyOrientation(
        udid: String,
        value: String,
        simulators: any Simulators
    ) -> OrientationOutcome {
        guard let orientation = DeviceOrientation(wireName: value) else {
            return .invalidValue
        }
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            return .unknownDevice
        }
        return sim.orientation().set(orientation) ? .ok : .dispatchFailed
    }

    /// Outcome of the status-bar routes — one case per HTTP-status
    /// branch. Lives next to the helpers so the route closures stay a
    /// `switch outcome → Response` translation.
    enum StatusBarOutcome: Equatable {
        case ok
        case invalidBody
        case emptyOverride
        case unknownDevice
        case dispatchFailed
    }

    /// Parse a `StatusBarOverride` from a JSON request body. Returns
    /// `nil` for malformed JSON or a present enum field with an
    /// unrecognised value — fail loud rather than silently dropping it.
    /// Numeric fields are accepted as JSON numbers; range clamping is
    /// the value type's job.
    static func parseStatusBarOverride(json: String) -> StatusBarOverride? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        var override = StatusBarOverride()
        override.time = dict["time"] as? String
        override.operatorName = dict["operatorName"] as? String
        if let raw = dict["dataNetwork"] as? String {
            guard let value = DataNetwork(wireName: raw) else { return nil }
            override.dataNetwork = value
        }
        if let raw = dict["wifiMode"] as? String {
            guard let value = WifiMode(wireName: raw) else { return nil }
            override.wifiMode = value
        }
        if let raw = dict["cellularMode"] as? String {
            guard let value = CellularMode(wireName: raw) else { return nil }
            override.cellularMode = value
        }
        if let raw = dict["batteryState"] as? String {
            guard let value = BatteryState(wireName: raw) else { return nil }
            override.batteryState = value
        }
        override.wifiBars = intField(dict["wifiBars"])
        override.cellularBars = intField(dict["cellularBars"])
        override.batteryLevel = intField(dict["batteryLevel"])
        return override
    }

    /// JSON numbers arrive as `NSNumber`; accept either an `Int` or a
    /// `Double` spelling so `3` and `3.0` both work.
    private static func intField(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        return nil
    }

    /// Pure parse + dispatch for `POST /simulators/:udid/status-bar`.
    /// Split from the route closure so unit tests can drive every
    /// branch with `MockSimulators` + `MockStatusBar`.
    static func applyStatusBar(
        udid: String,
        body: String,
        simulators: any Simulators
    ) async -> StatusBarOutcome {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            return .unknownDevice
        }
        guard let override = parseStatusBarOverride(json: body) else {
            return .invalidBody
        }
        guard !override.isEmpty else { return .emptyOverride }
        do {
            try await sim.statusBar().override(override)
            return .ok
        } catch {
            return .dispatchFailed
        }
    }

    /// Pure dispatch for `DELETE /simulators/:udid/status-bar`.
    static func clearStatusBar(
        udid: String,
        simulators: any Simulators
    ) async -> StatusBarOutcome {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            return .unknownDevice
        }
        do {
            try await sim.statusBar().clear()
            return .ok
        } catch {
            return .dispatchFailed
        }
    }

    /// Outcome of `GET /simulators/:udid/status-bar`.
    enum StatusBarReadOutcome: Equatable {
        case ok(StatusBarOverride)
        case unknownDevice
        case failed
    }

    /// Pure read for the status-bar GET route. Split from the closure so
    /// unit tests can drive every branch with `MockSimulators` +
    /// `MockStatusBar`.
    static func readStatusBar(
        udid: String,
        simulators: any Simulators
    ) async -> StatusBarReadOutcome {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            return .unknownDevice
        }
        do {
            return .ok(try await sim.statusBar().read())
        } catch {
            return .failed
        }
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
        guard let json = chromeJSONString(
            udid: udid, simulators: simulators, chromes: chromes
        ) else {
            return errorJSON("no chrome for udid \(udid)", status: .notFound)
        }
        return Response(
            status: .ok,
            headers: [.contentType: "application/json", .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(string: json))
        )
    }

    private static func definitionJSON(
        udid: String,
        simulators: any Simulators,
        chromes: any Chromes
    ) -> Response {
        guard let json = definitionJSONString(
            udid: udid, simulators: simulators, chromes: chromes
        ) else {
            return errorJSON("no definition for udid \(udid)", status: .notFound)
        }
        return Response(
            status: .ok,
            headers: [.contentType: "application/json", .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(string: json))
        )
    }

    /// Pure data producer for `chrome.json`. Internal so handler-level
    /// tests can drive it with mock `Simulators` + `Chromes` and assert
    /// on the JSON string directly. The route closure (`chromeJSON`)
    /// is the thin wrapper that builds the `Response`.
    ///
    /// Includes `imageUrl` per button — the actionable-bezel front end
    /// fetches each rasterized button from the
    /// `/simulators/<udid>/chrome-button/<name>.png` route below.
    static func chromeJSONString(
        udid: String,
        simulators: any Simulators,
        chromes: any Chromes
    ) -> String? {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid),
              let assets = sim.chrome(in: chromes) else {
            return nil
        }
        return assets.layoutJSON(
            buttonImageURLPrefix: "/simulators/\(udid)/chrome-button/"
        )
    }

    /// Pure data producer for the SDK bootstrap endpoint
    /// `/simulators/<udid>/definition.json`. Composes a
    /// `SimulatorDefinition` and serialises it. The route closure
    /// (`definitionJSON`) wraps the result into a 200/404 response.
    static func definitionJSONString(
        udid: String,
        simulators: any Simulators,
        chromes: any Chromes
    ) -> String? {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid),
              let assets = sim.chrome(in: chromes) else {
            return nil
        }
        let def = SimulatorDefinition.compose(
            from: sim,
            chrome: assets,
            urlPrefix: "/simulators/\(udid)"
        )
        return def.toJSON()
    }

    private static func screenshotJPEG(
        udid: String,
        quality: Double,
        scale: Int,
        simulators: any Simulators
    ) async -> Response {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            return errorJSON("unknown udid: \(udid)", status: .notFound)
        }
        do {
            let bytes = try await ScreenSnapshot.capture(
                screen: sim.screen(),
                quality: quality,
                scale: max(1, scale)
            )
            return Response(
                status: .ok,
                headers: [.contentType: "image/jpeg", .cacheControl: "no-cache"],
                body: .init(byteBuffer: ByteBuffer(data: bytes))
            )
        } catch {
            return errorJSON(String(describing: error), status: .internalServerError)
        }
    }

    private static func bezelPNG(
        udid: String,
        simulators: any Simulators,
        chromes: any Chromes,
        withButtons: Bool = true
    ) -> Response {
        guard let bytes = bezelImage(
            udid: udid, simulators: simulators,
            chromes: chromes, withButtons: withButtons
        ) else {
            return Response(
                status: .notFound,
                headers: [.contentType: "text/plain"],
                body: .init(byteBuffer: ByteBuffer(string: "no bezel for \(udid)"))
            )
        }
        return Response(
            status: .ok,
            headers: [.contentType: "image/png", .cacheControl: "public, max-age=86400"],
            body: .init(byteBuffer: ByteBuffer(data: bytes))
        )
    }

    /// Pure data producer for the bezel image. Returns `nil` for
    /// unknown UDIDs / chromes so the route closure can collapse to
    /// 404 uniformly.
    ///
    /// `withButtons: false` returns the bare device body (`?buttons=
    /// false` on the route) — the actionable-bezel front end layers
    /// per-button images on top, animating each independently.
    /// `withButtons: true` (the default) returns the merged composite
    /// — today's behaviour.
    static func bezelImage(
        udid: String,
        simulators: any Simulators,
        chromes: any Chromes,
        withButtons: Bool
    ) -> Data? {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid),
              let assets = sim.chrome(in: chromes) else {
            return nil
        }
        return withButtons ? assets.composite.data : assets.bareComposite.data
    }

    private static func chromeButtonPNG(
        udid: String,
        buttonFile: String,
        simulators: any Simulators,
        chromes: any Chromes
    ) -> Response {
        guard let bytes = chromeButtonImage(
            udid: udid, buttonFile: buttonFile,
            simulators: simulators, chromes: chromes
        ) else {
            return Response(
                status: .notFound,
                headers: [.contentType: "text/plain"],
                body: .init(byteBuffer: ByteBuffer(
                    string: "no button \(buttonFile) for \(udid)"
                ))
            )
        }
        return Response(
            status: .ok,
            headers: [.contentType: "image/png", .cacheControl: "public, max-age=86400"],
            body: .init(byteBuffer: ByteBuffer(data: bytes))
        )
    }

    /// Pure data producer for the per-button image route. `buttonFile`
    /// is the last URL path segment (e.g. `"powerButton.png"`). The
    /// `.png` extension is stripped — the front end may or may not
    /// include it, both spellings resolve the same button. Returns
    /// `nil` when the udid / chrome / button name is unknown so the
    /// route 404s uniformly.
    static func chromeButtonImage(
        udid: String,
        buttonFile: String,
        simulators: any Simulators,
        chromes: any Chromes
    ) -> Data? {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid),
              let assets = sim.chrome(in: chromes) else {
            return nil
        }
        let name: String = {
            if buttonFile.hasSuffix(".png") {
                return String(buttonFile.dropLast(4))
            }
            return buttonFile
        }()
        return assets.buttonImages[name]?.data
    }

    /// One WebSocket = one streaming session. Opens Screen + Stream
    /// + WS sink, runs until the client disconnects. Every inbound
    /// text frame is one JSON line dispatched in this order:
    ///   1. ReconfigParser   — set_bitrate / set_fps / set_scale
    ///   2. stream verbs     — force_idr / snapshot
    ///   3. GestureDispatcher — tap / swipe / touch1-* / touch2-* /
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

        do {
            try stream.start(on: screen)
        } catch {
            try? await outbound.write(.text(
                #"{"ok":false,"error":"\#(jsonEscape(String(describing: error)))"}"#
            ))
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
                if await handleDescribeUI(
                    line: line, sim: sim, outbound: outbound
                ) {
                    continue
                }
                handleInbound(
                    line: line,
                    stream: stream,
                    dispatcher: dispatcher
                )
            }
        } catch {
            // socket closed; defer cleans up
        }
    }

    /// `describe_ui` text message — needs the `Simulator` (to reach
    /// the AX port) and the outbound writer (to ship the result
    /// back), neither of which `handleInbound` carries. Returns
    /// `true` when the line was a `describe_ui` envelope (handled
    /// or rejected with an error JSON), `false` for any other
    /// shape so the caller falls through to the gesture / reconfig
    /// pipeline.
    private static func handleDescribeUI(
        line: String,
        sim: Simulator,
        outbound: WebSocketOutboundWriter
    ) async -> Bool {
        guard let data = line.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (dict["type"] as? String) == "describe_ui" else {
            return false
        }
        let ax = sim.accessibility()
        let result: AXNode?
        do {
            if let xv = (dict["x"] as? Double) ?? (dict["x"] as? Int).map(Double.init),
               let yv = (dict["y"] as? Double) ?? (dict["y"] as? Int).map(Double.init) {
                result = try ax.describeAt(point: Point(x: xv, y: yv))
            } else {
                result = try ax.describeAll()
            }
        } catch {
            try? await outbound.write(.text(
                #"{"type":"describe_ui_result","ok":false,"error":"\#(jsonEscape(String(describing: error)))"}"#
            ))
            return true
        }
        if let tree = result {
            try? await outbound.write(.text(
                #"{"type":"describe_ui_result","ok":true,"tree":\#(tree.json)}"#
            ))
        } else {
            try? await outbound.write(.text(
                #"{"type":"describe_ui_result","ok":false,"error":"no accessibility data"}"#
            ))
        }
        return true
    }

    /// Register the `/simulators/:udid/logs` WebSocket route. Lives
    /// in its own helper because Hummingbird's router-builder
    /// inference grinds to a halt when too many `router.ws` /
    /// `router.get` closures share a single function body.
    private func registerLogsRoute(on router: Router<BasicWebSocketRequestContext>) {
        let simulators = self.simulators
        let bindHost = self.host
        let bindPort = self.port
        let trustedWebSocketUpgrade:
            @Sendable (Request, BasicWebSocketRequestContext) async throws -> RouterShouldUpgrade = {
                request, _ in
                Self.isTrustedBrowserRequest(
                    request, bindHost: bindHost, bindPort: bindPort
                ) ? .upgrade([:]) : .dontUpgrade
            }
        router.ws(
            "/simulators/:udid/logs",
            shouldUpgrade: trustedWebSocketUpgrade
        ) { inbound, outbound, context in
            let req = context.request
            let opts = LogsRouteOptions.from(request: req)
            await Self.logsWS(
                opts: opts,
                simulators: simulators,
                inbound: inbound,
                outbound: outbound
            )
        }
    }

    /// Live log-stream over the dedicated `/simulators/:udid/logs`
    /// WebSocket. Filter is fixed at connect time via query string
    /// (`level`, `style`, `predicate`, `bundleId`). The spawned
    /// `/usr/bin/log stream` child runs for the lifetime of the
    /// socket; closing the socket from either end tears it down.
    ///
    /// Wire envelopes (server → client text frames):
    ///   {"type":"log_started"}
    ///   {"type":"log","lines":["<line>", "<line>", …]}
    ///   {"type":"log_stopped","reason":"<text>"}
    ///
    /// Lines are coalesced through `LogBatcher` (size cap + 50 ms
    /// window): per-line WS frames pegged the browser's main thread
    /// at CoreDuet-chatter rates because the per-frame parse +
    /// dispatch + render cost dwarfs the bytes themselves. One
    /// frame per ~50 ms drops that to ~20 frames/sec and decouples
    /// log volume from UI responsiveness.
    ///
    /// Client → server: a single `{"type":"stop"}` text frame
    /// terminates early. Otherwise the server waits for the child
    /// to exit or the socket to close.
    private static func logsWS(
        opts: LogsRouteOptions,
        simulators: any Simulators,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        guard !opts.udid.isEmpty, let sim = simulators.find(udid: opts.udid) else {
            try? await outbound.write(.text(#"{"type":"log_stopped","reason":"unknown udid"}"#))
            return
        }
        guard let lvl = LogFilter.Level(wire: opts.level) else {
            try? await outbound.write(.text(
                #"{"type":"log_stopped","reason":"invalid level: \#(opts.level)"}"#
            ))
            return
        }
        guard let sty = LogFilter.Style(wire: opts.style) else {
            try? await outbound.write(.text(
                #"{"type":"log_stopped","reason":"invalid style: \#(opts.style)"}"#
            ))
            return
        }
        let filter = LogFilter(
            level: lvl, style: sty,
            predicate: opts.predicate, bundleId: opts.bundleId
        )

        let stream = sim.logs()
        let lineQueue = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(2048))

        do {
            try stream.start(
                filter: filter,
                onLine: { line in
                    lineQueue.continuation.yield(line)
                },
                onTerminate: { _ in
                    lineQueue.continuation.finish()
                }
            )
        } catch {
            try? await outbound.write(.text(
                #"{"type":"log_stopped","reason":"\#(jsonEscape(String(describing: error)))"}"#
            ))
            return
        }

        try? await outbound.write(.text(#"{"type":"log_started"}"#))
        defer { stream.stop() }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // Multiplex lines and a 50ms ticker into one stream so a
                // single consumer can own the batcher without locking.
                enum Event { case line(String); case tick; case end }
                let events = AsyncStream<Event>(bufferingPolicy: .bufferingNewest(4096)) { cont in
                    let lineTask = Task {
                        for await line in lineQueue.stream {
                            cont.yield(.line(line))
                        }
                        cont.yield(.end)
                        cont.finish()
                    }
                    let tickTask = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            if Task.isCancelled { break }
                            cont.yield(.tick)
                        }
                    }
                    cont.onTermination = { _ in
                        lineTask.cancel()
                        tickTask.cancel()
                    }
                }

                var batcher = LogBatcher(maxLines: 200, windowMs: 50)
                consumer: for await event in events {
                    let batch: [String]?
                    switch event {
                    case .line(let line): batch = batcher.ingest(line, now: Date())
                    case .tick:           batch = batcher.tick(now: Date())
                    case .end:
                        if let final = batcher.flush() {
                            _ = try? await outbound.write(.text(envelope(forBatch: final)))
                        }
                        break consumer
                    }
                    if let batch {
                        if (try? await outbound.write(.text(envelope(forBatch: batch)))) == nil {
                            break consumer
                        }
                    }
                }
            }
            group.addTask {
                do {
                    for try await frame in inbound {
                        guard frame.opcode == .text else { continue }
                        let line = String(buffer: frame.data)
                        if let data = line.data(using: .utf8),
                           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           (dict["type"] as? String) == "stop" {
                            break
                        }
                    }
                } catch {
                    // socket closed; defer cleans up
                }
            }
            await group.next()
            group.cancelAll()
        }
        try? await outbound.write(.text(#"{"type":"log_stopped","reason":"client closed"}"#))
    }

    /// Register the `/simulators/:udid/camera` WebSocket route — the
    /// browser's camera picker drives this. One WS per simulator; the
    /// session is set up lazily on the first `camera_start`. Closing
    /// the socket tears down capture but leaves the dylib's launchd
    /// env in place, so a freshly-launched iOS app still loads the
    /// VirtualCamera dylib without re-arming.
    private func registerCameraRoute(on router: Router<BasicWebSocketRequestContext>) {
        let simulators = self.simulators
        let bindHost = self.host
        let bindPort = self.port
        let trustedWebSocketUpgrade:
            @Sendable (Request, BasicWebSocketRequestContext) async throws -> RouterShouldUpgrade = {
                request, _ in
                Self.isTrustedBrowserRequest(
                    request, bindHost: bindHost, bindPort: bindPort
                ) ? .upgrade([:]) : .dontUpgrade
            }
        router.ws(
            "/simulators/:udid/camera",
            shouldUpgrade: trustedWebSocketUpgrade
        ) { inbound, outbound, context in
            await Self.cameraWS(
                udid: Self.udidParam(context.request),
                simulators: simulators,
                inbound: inbound,
                outbound: outbound
            )
        }
    }

    /// One WS lifecycle. On connect: push the device list. Then read
    /// JSON messages forever, dispatching to the per-WS
    /// `CameraSession`. The session writes BGRA frames into
    /// `/tmp/SimCam.bgra` (the path the VirtualCamera dylib reads);
    /// `VirtualCameraInstaller` resolves the bundled dylib's
    /// per-hash dest path, and `SimctlSimulatorInjection` arms the
    /// simulator's launchd env to point at it.
    @MainActor
    private static func cameraWS(
        udid: String,
        simulators: any Simulators,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            try? await outbound.write(.text(
                #"{"type":"camera_state","ok":false,"error":"unknown udid"}"#
            ))
            return
        }
        let cameras = AVCameras()
        let sink: any CameraFrameSink
        do {
            sink = try SharedMemoryFrameSink(path: "/tmp/SimCam.bgra")
        } catch {
            try? await outbound.write(.text(
                #"{"type":"camera_state","ok":false,"error":"\#(jsonEscape(String(describing: error)))"}"#
            ))
            return
        }
        let session = CameraSession(
            capture: AVCameraCapture(),
            sink: sink,
            injection: SimctlSimulatorInjection()
        )

        // Push the initial device list so the picker can render
        // immediately without an extra round-trip.
        await sendDeviceList(cameras: cameras, outbound: outbound)

        defer { Task { await session.stop() } }

        // 1-Hz heartbeat: sample FPS off the frame counter and push
        // `camera_state` so the browser's "streaming · X fps" readout
        // updates while frames flow. Detached child task — cancelled
        // when the WS loop exits.
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                session.sampleFPS()
                if case .streaming = session.phase {
                    await sendCameraState(session: session, outbound: outbound)
                }
            }
        }
        defer { heartbeat.cancel() }

        do {
            for try await frame in inbound {
                guard frame.opcode == .text else { continue }
                let line = String(buffer: frame.data)
                await handleCameraLine(
                    line: line,
                    cameras: cameras,
                    session: session,
                    sim: sim,
                    outbound: outbound
                )
            }
        } catch {
            // socket closed; defer cleans up
        }
    }

    @MainActor
    private static func handleCameraLine(
        line: String,
        cameras: any Cameras,
        session: CameraSession,
        sim: any Simulator,
        outbound: WebSocketOutboundWriter
    ) async {
        guard let data = line.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let msg: CameraMessage
        do { msg = try CameraMessage.parse(dict) } catch {
            try? await outbound.write(.text(
                #"{"type":"camera_state","ok":false,"error":"\#(jsonEscape(String(describing: error)))"}"#
            ))
            return
        }

        switch msg {
        case .list:
            await sendDeviceList(cameras: cameras, outbound: outbound)
        case .start(let uid, let flags):
            session.setFlags(flags)
            let devices = await cameras.available()
            guard let device = devices.first(where: { $0.uid == uid }) else {
                try? await outbound.write(.text(
                    #"{"type":"camera_state","ok":false,"error":"unknown camera deviceUID"}"#
                ))
                return
            }
            guard let dylibPath = VirtualCameraInstaller.installIfNeeded() else {
                try? await outbound.write(.text(
                    #"{"type":"camera_state","ok":false,"error":"VirtualCamera.dylib is not bundled in this build"}"#
                ))
                return
            }
            await session.start(device: device, on: sim, dylibPath: dylibPath)
            await sendCameraState(session: session, outbound: outbound)
        case .stop:
            await session.stop()
            await sendCameraState(session: session, outbound: outbound)
        case .setFlags(let flags):
            session.setFlags(flags)
            await sendCameraState(session: session, outbound: outbound)
        }
    }

    @MainActor
    private static func sendDeviceList(
        cameras: any Cameras,
        outbound: WebSocketOutboundWriter
    ) async {
        let devices = await cameras.available()
        let arr = devices.map { $0.wireDictionary }
        let payload: [String: Any] = ["type": "camera_devices", "devices": arr]
        if let bytes = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: bytes, encoding: .utf8) {
            try? await outbound.write(.text(json))
        }
    }

    @MainActor
    private static func sendCameraState(
        session: CameraSession,
        outbound: WebSocketOutboundWriter
    ) async {
        let phase: String
        var deviceUID: String? = nil
        if case .streaming(let uid) = session.phase {
            phase = "streaming"
            deviceUID = uid
        } else {
            phase = "idle"
        }
        var payload: [String: Any] = [
            "type": "camera_state",
            "ok": session.lastError == nil,
            "phase": phase,
            "fps": session.fps,
        ]
        if let uid = deviceUID { payload["device"] = uid }
        if let err = session.lastError { payload["error"] = err }
        if let bytes = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: bytes, encoding: .utf8) {
            try? await outbound.write(.text(json))
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

    /// Pull the UDID out of a `/simulators/<udid>/<verb>` request.
    /// `<verb>` is the last segment, `<udid>` the one before.
    private static func udidParam(_ request: Request) -> String {
        let parts = request.uri.path.split(separator: "/")
        guard parts.count >= 3 else { return "" }
        return String(parts[parts.count - 2]).removingPercentEncoding ?? ""
    }


    private static func redirect(to path: String) -> Response {
        Response(
            status: .found,
            headers: [.location: path],
            body: .init(byteBuffer: ByteBuffer(string: ""))
        )
    }

    private static func rejectUntrustedBrowserRequest(
        _ request: Request,
        bindHost: String,
        bindPort: Int
    ) -> Response? {
        guard !isTrustedBrowserRequest(request, bindHost: bindHost, bindPort: bindPort) else {
            return nil
        }
        return errorJSON("forbidden origin", status: .forbidden)
    }

    /// Browsers can drive localhost services from another site unless the
    /// service checks `Origin`. For a loopback bind, also reject DNS-rebind
    /// style `Host` values that are not loopback names.
    static func isTrustedBrowserRequest(
        _ request: Request,
        bindHost: String,
        bindPort: Int
    ) -> Bool {
        if isLoopbackBind(bindHost),
           let authority = request.head.authority,
           let requestHost = parseAuthority(authority)?.host,
           !isLoopbackHost(requestHost) {
            return false
        }

        if let fetchSite = request.headers[.secFetchSite]?.lowercased(),
           fetchSite == "cross-site" {
            return false
        }

        guard let origin = request.headers[.origin] else { return true }
        guard let originURL = URLComponents(string: origin),
              let originHost = originURL.host else {
            return false
        }

        let authority = request.head.authority ?? "\(bindHost):\(bindPort)"
        guard let requestAuthority = parseAuthority(authority) else { return false }
        let requestPort = requestAuthority.port ?? bindPort
        let originPort = originURL.port ?? defaultPort(for: originURL.scheme)

        if isLoopbackBind(bindHost) {
            return isLoopbackHost(originHost)
                && isLoopbackHost(requestAuthority.host)
                && (originPort ?? requestPort) == requestPort
        }

        return originHost.caseInsensitiveCompare(requestAuthority.host) == .orderedSame
            && (originPort ?? requestPort) == requestPort
    }

    private static func parseAuthority(_ raw: String) -> (host: String, port: Int?)? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("["),
           let close = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
            return (host, port)
        }

        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 1 { return (String(parts[0]), nil) }
        guard let last = parts.last, let port = Int(last) else { return (value, nil) }
        return (parts.dropLast().joined(separator: ":"), port)
    }

    private static func defaultPort(for scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "http", "ws": return 80
        case "https", "wss": return 443
        default: return nil
        }
    }

    private static func isLoopbackBind(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return lower == "localhost" || lower == "::1" || lower.hasPrefix("127.")
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return lower == "localhost" || lower == "::1" || lower.hasPrefix("127.")
    }
}

// MARK: - tiny response helpers

private let jsonOK = Response(
    status: .ok,
    headers: [.contentType: "application/json"],
    body: .init(byteBuffer: ByteBuffer(string: "{\"ok\":true}"))
)

private func errorJSON(_ message: String, status: HTTPResponse.Status) -> Response {
    return Response(
        status: status,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(string:
            "{\"ok\":false,\"error\":\"\(jsonEscape(message))\"}"
        ))
    )
}

/// Plain-old-data carrier for the `/simulators/:udid/logs` query
/// string + path UDID. Pulled into its own struct so the route
/// closure stays a one-liner — Hummingbird's router-builder
/// inference deteriorates fast when the closure body argues with
/// 8-parameter calls inline.
private struct LogsRouteOptions: Sendable {
    let udid: String
    let level: String
    let style: String
    let predicate: String?
    let bundleId: String?

    static func from(request: Request) -> LogsRouteOptions {
        let parts = request.uri.path.split(separator: "/")
        var udid = ""
        if parts.count >= 3 {
            udid = String(parts[parts.count - 2]).removingPercentEncoding ?? ""
        }
        let q = request.uri.queryParameters
        let level: String     = q.get("level").map { String($0) }     ?? "info"
        let style: String     = q.get("style").map { String($0) }     ?? "default"
        let predicate: String? = q.get("predicate").map { String($0) }
        let bundleId: String?  = q.get("bundleId").map { String($0) }
        return LogsRouteOptions(
            udid: udid,
            level: level,
            style: style,
            predicate: predicate,
            bundleId: bundleId
        )
    }
}

/// Minimal JSON-string escaper: backslash, quote, and the ASCII
/// control characters that JSON forbids unescaped. Sufficient for
/// embedding a log line into a `{"line":"…"}` envelope without
/// rebuilding the whole dict via JSONSerialization.
private func jsonEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count + 8)
    for ch in s.unicodeScalars {
        switch ch {
        case "\"":  out.append("\\\"")
        case "\\":  out.append("\\\\")
        case "\n":  out.append("\\n")
        case "\r":  out.append("\\r")
        case "\t":  out.append("\\t")
        case "\u{08}": out.append("\\b")
        case "\u{0C}": out.append("\\f")
        default:
            if ch.value < 0x20 {
                out.append(String(format: "\\u%04x", ch.value))
            } else {
                out.append(Character(ch))
            }
        }
    }
    return out
}

/// Build the `{"type":"log","lines":[…]}` envelope for one drained
/// `LogBatcher` batch. Hand-rolled rather than going through
/// `JSONSerialization` because the hot path runs at most ~20×/sec
/// per logs WS and each entry is already a UTF-8 string we can
/// escape in place.
private func envelope(forBatch lines: [String]) -> String {
    var s = #"{"type":"log","lines":["#
    for (i, line) in lines.enumerated() {
        if i > 0 { s.append(",") }
        s.append("\"")
        s.append(jsonEscape(line))
        s.append("\"")
    }
    s.append("]}")
    return s
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

private extension HTTPField.Name {
    static let secFetchSite = Self("Sec-Fetch-Site")!
    static let contentSecurityPolicy = Self("Content-Security-Policy")!
}
