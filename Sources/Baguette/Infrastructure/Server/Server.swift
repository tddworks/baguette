import CoreGraphics
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import ImageIO
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
///   GET  /simulators/:udid/screenshot.jpg   → JPEG (?quality=&scale=&size=&fit=&background=)
///   GET  /simulators/:udid/screenshot.png   → PNG  (same query knobs)
///   GET  /simulators/:udid/screenshot-bezel.png → PNG composited into the
///                                             device chrome (+ ?buttons=)
///   WS   /simulators/:udid/stream?format=   → frames      (TODO)
///   WS   /simulators/:udid/stream.3d.:format → live 3D AVCC/MJPEG frames
///   GET  /devices.json                      → connected physical devices
///   WS   /devices/companion/video           → companion app video ingest
///   WS   /devices/:udid/stream?format=      → physical-device mirror frames
///   GET  /<file>.{html,js,css}              → static UI asset
///
/// Static UI siblings live at the *root* (e.g. `GET /sim-list.js`)
/// so the page at `/simulators` resolves `<script src="sim-list.js">`
/// to a sibling — no prefix juggling, no conflict with the
/// `/simulators/:udid` resource tree (UDIDs don't end in `.js`).
struct Server: Sendable {
    let simulators: any Simulators
    let chromes: any Chromes
    let models: any DeviceModels
    let deviceRenderer: any DeviceRenderer
    let plugins: any Plugins
    let host: String
    let port: Int
    let allowedHosts: Set<String>
    /// Capability grants, one per plugin-command invocation. A plugin
    /// subprocess authenticates with the token it was handed, which
    /// carries exactly its manifest's declared capabilities and dies
    /// with the command. See `PluginGrants`.
    let grants: PluginGrants

    /// Per-simulator motion state. A reference type held by this struct
    /// because motion is the one surface here that *is* stateful: the
    /// pedometer's running totals have to survive between requests, and the
    /// location routes need to reach them to drive the activity.
    let motionSessions: MotionSessions

    /// Device-twin state: connected companions and their per-device
    /// video ingest hubs. Reference types for the same reason as
    /// `motionSessions` — membership and decoder sessions must
    /// survive between socket connections.
    let devices: LiveDevices
    let twinScreens: TwinScreens

    init(
        simulators: any Simulators,
        chromes: any Chromes,
        models: any DeviceModels = DeviceModelCatalog.empty,
        deviceRenderer: any DeviceRenderer = RealityKitDeviceRenderer(),
        plugins: any Plugins = FileSystemPlugins(roots: []),
        host: String = "127.0.0.1",
        port: Int = 8421,
        allowedHosts: [String] = [],
        grants: PluginGrants = PluginGrants(),
        motionSessions: MotionSessions = MotionSessions(),
        devices: LiveDevices = LiveDevices(),
        twinScreens: TwinScreens = TwinScreens()
    ) {
        self.simulators = simulators
        self.motionSessions = motionSessions
        self.devices = devices
        self.twinScreens = twinScreens
        self.chromes = chromes
        self.models = models
        self.deviceRenderer = deviceRenderer
        self.plugins = plugins
        self.host = host
        self.port = port
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.grants = grants
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
        let allowedHosts = self.allowedHosts
        if !allowedHosts.isEmpty {
            router.add(middleware: AllowedHostsCORSMiddleware(allowedHosts: allowedHosts))
        }
        // Capability enforcement sits in front of every route rather than
        // inside the handful that thought to ask. A plugin presenting a
        // grant gets exactly the routes its manifest declared and nothing
        // else — including routes nobody has mapped to a capability yet,
        // which are closed by construction. Requests with no grant are
        // untouched here and still answer to the origin checks below.
        router.add(middleware: PluginGrantMiddleware(grants: self.grants))
        let rejectUntrustedBrowser: @Sendable (Request) -> Response? = { request in
            Self.rejectUntrustedBrowserRequest(
                request, bindHost: bindHost, bindPort: bindPort, allowedHosts: allowedHosts
            )
        }
        let trustedWebSocketUpgrade:
            @Sendable (Request, BasicWebSocketRequestContext) async throws -> RouterShouldUpgrade = {
                request, _ in
                Self.isTrustedBrowserRequest(
                    request, bindHost: bindHost, bindPort: bindPort, allowedHosts: allowedHosts
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

        registerPluginRoutes(on: router, rejectUntrustedBrowser: rejectUntrustedBrowser)
        registerBakeryRoutes(on: router, rejectUntrustedBrowser: rejectUntrustedBrowser)
        registerInterfaceRoutes(on: router, rejectUntrustedBrowser: rejectUntrustedBrowser)
        registerCompanionScreenRoutes(on: router, rejectUntrustedBrowser: rejectUntrustedBrowser)
        registerDeepLinkRoutes(on: router, rejectUntrustedBrowser: rejectUntrustedBrowser)
        registerDeviceTwinRoutes(
            on: router,
            rejectUntrustedBrowser: rejectUntrustedBrowser,
            trustedWebSocketUpgrade: trustedWebSocketUpgrade
        )

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

        // Shake — `POST` fires a UIKit motionShake via
        // `simulator.shake().shake()`, backed by `simctl spawn
        // notifyutil`. Pure dispatch lives in `Server.applyShake` for
        // unit testing.
        router.post("/simulators/:udid/shake") { [simulators] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            switch await Self.applyShake(udid: Self.udidParam(r), simulators: simulators) {
            case .ok:
                return jsonOK
            case .unknownDevice:
                return errorJSON("unknown udid: \(Self.udidParam(r))", status: .notFound)
            case .dispatchFailed:
                return errorJSON("shake failed (simctl error)", status: .internalServerError)
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

        // Location — `POST` sets the simulated GPS position (a single
        // point; a moving route when the body carries `waypoints`; or the
        // joystick's walk vector when it carries `bearing`); `DELETE`
        // clears it back to live. Backed by `simctl location`; pure parse
        // + dispatch lives in `Server.applyLocation` / `clearLocation`
        // for unit testing.
        router.post("/simulators/:udid/location") { [simulators, motionSessions] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let buffer = try? await r.body.collect(upTo: 64 * 1024)
            let body = buffer.map { String(buffer: $0) } ?? ""
            switch await Self.applyLocation(
                udid: Self.udidParam(r), body: body, simulators: simulators,
                sessions: motionSessions
            ) {
            case .ok:
                return jsonOK
            case .invalidBody:
                return errorJSON("location body must be a point {latitude,longitude}, a {waypoints:[…]} route, or a {latitude,longitude,bearing,speed} walk", status: .badRequest)
            case .unknownDevice:
                return errorJSON("unknown udid: \(Self.udidParam(r))", status: .notFound)
            case .dispatchFailed:
                return errorJSON("location change failed (simctl error)", status: .internalServerError)
            }
        }
        router.delete("/simulators/:udid/location") { [simulators, motionSessions] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            switch await Self.clearLocation(udid: Self.udidParam(r), simulators: simulators,
                                            sessions: motionSessions) {
            case .ok:
                return jsonOK
            case .unknownDevice:
                return errorJSON("unknown udid: \(Self.udidParam(r))", status: .notFound)
            case .dispatchFailed:
                return errorJSON("location clear failed (simctl error)", status: .internalServerError)
            case .invalidBody:
                return jsonOK // unreachable for clear; keep the switch total
            }
        }

        // Motion — `POST` arms the injected dylib and states what the device
        // is doing; `DELETE` parks it as stationary and disarms. Once armed,
        // the location routes above drive the activity from the speed the
        // device is moving at, so the browser's joystick needs no new wire.
        //
        // Unlike location there is no simctl verb behind this: all three
        // CoreMotion surfaces report unavailable in a stock simulator. Only
        // apps launched *after* the POST see anything — dyld inserts at exec
        // time. See `docs/features/motion.md`.
        router.post("/simulators/:udid/motion") { [simulators, motionSessions] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let buffer = try? await r.body.collect(upTo: 64 * 1024)
            let body = buffer.map { String(buffer: $0) } ?? ""
            switch await Self.applyMotion(
                udid: Self.udidParam(r), body: body, simulators: simulators,
                sessions: motionSessions
            ) {
            case .ok:
                return Self.jsonResponse(
                    await Self.motionStateJSON(udid: Self.udidParam(r), sessions: motionSessions))
            case .invalidBody:
                return errorJSON(
                    "motion body must name an activity: stationary, walking, running, cycling, or automotive",
                    status: .badRequest)
            case .unknownDevice:
                return errorJSON("unknown udid: \(Self.udidParam(r))", status: .notFound)
            case .dispatchFailed:
                return errorJSON(
                    "motion failed — is VirtualMotion.dylib bundled in this build?",
                    status: .internalServerError)
            }
        }
        // Read-back for the card's readout — the one place motion differs
        // from location, which has no GET because simctl cannot report the
        // active position. Here the state is ours, so we can answer.
        router.get("/simulators/:udid/motion") { [simulators, motionSessions] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            guard let json = await Self.motionState(
                udid: Self.udidParam(r), simulators: simulators, sessions: motionSessions
            ) else {
                return errorJSON("unknown udid: \(Self.udidParam(r))", status: .notFound)
            }
            return Self.jsonResponse(json)
        }
        router.delete("/simulators/:udid/motion") { [simulators, motionSessions] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            switch await Self.stopMotion(udid: Self.udidParam(r), simulators: simulators,
                                         sessions: motionSessions) {
            case .ok:
                return jsonOK
            case .unknownDevice:
                return errorJSON("unknown udid: \(Self.udidParam(r))", status: .notFound)
            case .invalidBody, .dispatchFailed:
                return errorJSON("motion stop failed", status: .internalServerError)
            }
        }

        // Network conditioning — `POST` arms the injected dylib and states
        // how degraded the network is; `GET` reports what this simulator is
        // actually subject to; `DELETE` stops conditioning, including for
        // apps that are already running.
        //
        // Like motion there is no simctl verb behind this, and for a
        // sharper reason: the host's own tooling (Network Link Conditioner,
        // and the dnctl/pfctl rules under it) is system-wide, so scoping to
        // one simulator means injecting into the app under test. Only apps
        // launched *after* the POST are conditioned — dyld inserts at exec
        // time — though changing the condition afterwards reaches a running
        // app fine. See `docs/features/network.md`.
        router.post("/simulators/:udid/network") { [simulators] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let buffer = try? await r.body.collect(upTo: 64 * 1024)
            let body = buffer.map { String(buffer: $0) } ?? ""
            switch await Self.applyNetwork(
                udid: Self.udidParam(r), body: body, simulators: simulators
            ) {
            case .ok:
                guard let json = await Self.networkStateJSON(
                    udid: Self.udidParam(r), simulators: simulators
                ) else {
                    return errorJSON("unknown udid: \(Self.udidParam(r))", status: .notFound)
                }
                return Self.jsonResponse(json)
            case .invalidBody:
                return errorJSON(
                    "network body must name exactly one of: a profile "
                    + "(\"profile\":\"3g\"), explicit numbers (\"latencyMs\", "
                    + "\"bandwidthKbps\", \"lossPercent\"), or \"offline\":true",
                    status: .badRequest)
            case .unknownDevice:
                return errorJSON("unknown udid: \(Self.udidParam(r))", status: .notFound)
            case .dispatchFailed:
                return errorJSON(
                    "network conditioning failed — is VirtualNetwork.dylib bundled "
                    + "in this build?",
                    status: .internalServerError)
            }
        }
        // Read-back for the card's readout and, more to the point, its armed
        // badge. A throttle nobody remembers arming presents as "the app is
        // slow", so the UI has to be able to say plainly that one is on.
        router.get("/simulators/:udid/network") { [simulators] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            guard let json = await Self.networkStateJSON(
                udid: Self.udidParam(r), simulators: simulators
            ) else {
                return errorJSON("unknown udid: \(Self.udidParam(r))", status: .notFound)
            }
            return Self.jsonResponse(json)
        }
        router.delete("/simulators/:udid/network") { [simulators] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            switch await Self.clearNetwork(udid: Self.udidParam(r), simulators: simulators) {
            case .ok:
                return jsonOK
            case .unknownDevice:
                return errorJSON("unknown udid: \(Self.udidParam(r))", status: .notFound)
            case .invalidBody, .dispatchFailed:
                return errorJSON("network clear failed", status: .internalServerError)
            }
        }

        // File upload — drag-and-drop a file onto the device view. One
        // dumb entry point: the browser POSTs raw bytes with `?name=`,
        // and `Server.addFile` routes by extension to the right device
        // collection (apps → install, media → Photos). Anything with no
        // home on a simulator is refused with 415, never swallowed.
        //
        // Browser-only. Because it classifies by extension, the
        // authority it confers would depend on the bytes — so it is the
        // one upload route `PluginRoute` maps to nothing. Plugins use
        // `/apps` and `/media` below, which say which power they mean.
        router.post("/simulators/:udid/files") { [simulators] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            return await Self.handleUpload(r, simulators: simulators, allowing: .all)
        }

        // The two narrow halves, each guarded by its own capability.
        // Same plumbing, different answer to "what may land here".
        router.post("/simulators/:udid/apps") { [simulators] r, _ in
            if Self.presentsGrant(r) == false, let rejected = rejectUntrustedBrowser(r) {
                return rejected
            }
            return await Self.handleUpload(r, simulators: simulators, allowing: .apps)
        }

        router.post("/simulators/:udid/media") { [simulators] r, _ in
            if Self.presentsGrant(r) == false, let rejected = rejectUntrustedBrowser(r) {
                return rejected
            }
            return await Self.handleUpload(r, simulators: simulators, allowing: .media)
        }

        // Camera source upload: an image / video the simulator's camera
        // streams from. Unlike /files (consumed synchronously by simctl
        // inside the request), these bytes must OUTLIVE the POST — the
        // camera WebSocket streams them later — so they're staged into a
        // persistent per-udid slot and remembered by CameraSourceStaging.
        router.post("/simulators/:udid/camera-source") { [simulators] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let udid = Self.udidParam(r)
            // Resolve the udid against a real device before it names a
            // directory — `udidParam` percent-decodes, so an unchecked
            // udid can carry `..` into the staging root. `CameraSourceSlot`
            // refuses those too; this is the same check `/files` makes and
            // it keeps the error honest ("unknown udid" beats a slot error).
            guard !udid.isEmpty, simulators.find(udid: udid) != nil else {
                return errorJSON("unknown udid: \(udid)", status: .notFound)
            }
            let rawName = String(r.uri.queryParameters.get("name") ?? "source")
            let filename = (rawName as NSString).lastPathComponent
            let nameURL = URL(fileURLWithPath: filename)

            // Cheap reject before reading the body: only images/videos
            // can drive the camera.
            guard let kind = CameraMediaKind.at(nameURL) else {
                return errorJSON(
                    "no camera source for .\(nameURL.pathExtension) (images and videos only)",
                    status: .unsupportedMediaType
                )
            }
            guard let buffer = try? await r.body.collect(upTo: Self.maxUploadBytes) else {
                return errorJSON("upload too large (max \(Self.maxUploadBytes / (1 << 20)) MiB) or unreadable", status: .badRequest)
            }
            do {
                try await CameraSourceStaging.shared.stage(
                    udid: udid, filename: filename, data: Data(buffer: buffer)
                )
            } catch {
                return errorJSON("could not stage camera source: \(error)", status: .internalServerError)
            }
            let json = "{\"ok\":true,\"kind\":\"\(kind == .image ? "image" : "video")\"}"
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: ByteBuffer(string: json)))
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

        // One-shot still of the current framebuffer. Spins up Screen,
        // awaits one IOSurface, encodes, and tears down — `?quality=`
        // and `?scale=` mirror the WS stream knobs for parity, while
        // `?size=` / `?fit=` / `?background=` speak the shared capture
        // vocabulary (`CaptureSize`) so "App Store 6.9" means the same
        // pixels here, in the toolbar picker, and on the CLI.
        //
        // Two extensions, one handler. A browser picks its decoder off
        // the URL extension and nothing else, so `.png` has to be its
        // own route rather than a `?format=` knob hung off `.jpg` —
        // that's the entire reason the second registration exists.
        for format in Self.CaptureImageFormat.allCases {
            router.get("/simulators/:udid/screenshot.\(format.pathExtension)") {
                [simulators] r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                let options: Self.CaptureOptions
                do {
                    options = try Self.captureOptions(query: r)
                } catch let error as Self.CaptureQueryError {
                    return errorJSON(error.message, status: .badRequest)
                }
                return await Self.screenshot(
                    udid: Self.udidParam(r),
                    quality: r.uri.queryParameters.get("quality").flatMap(Double.init)
                        ?? format.defaultQuality,
                    scale: r.uri.queryParameters.get("scale").flatMap(Int.init) ?? 1,
                    format: format,
                    options: options,
                    simulators: simulators
                )
            }
        }

        // The same still, composited into the device's DeviceKit
        // chrome server-side. `bezel.png` + the framebuffer layered in
        // CSS is what the browser does; this route exists for everyone
        // who isn't a browser — `curl` in a marketing script, a CI job
        // producing App Store shots, the device-farm wall's own
        // thumbnails. `?buttons=` matches `bezel.png`'s bare/rest
        // variants; `?size=` / `?fit=` / `?background=` are the same
        // knobs as the bare screenshot, applied to the composite.
        router.get("/simulators/:udid/screenshot-bezel.png") {
            [simulators, chromes] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let options: Self.CaptureOptions
            do {
                options = try Self.captureOptions(query: r)
            } catch let error as Self.CaptureQueryError {
                return errorJSON(error.message, status: .badRequest)
            }
            return await Self.screenshotBezelPNG(
                udid: Self.udidParam(r),
                quality: r.uri.queryParameters.get("quality").flatMap(Double.init)
                    ?? Self.CaptureImageFormat.png.defaultQuality,
                scale: r.uri.queryParameters.get("scale").flatMap(Int.init) ?? 1,
                withButtons: r.uri.queryParameters.get("buttons")
                    .map { $0.lowercased() != "false" } ?? true,
                options: options,
                simulators: simulators,
                chromes: chromes
            )
        }

        // Data-driven 3D model metadata for the focus-mode inspector.
        // Only public IDs / labels / preview colors cross this boundary;
        // raw USD paths and variant names remain server-side.
        router.get("/simulators/:udid/3d-model.json") { [simulators, models] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let udid = Self.udidParam(r)
            guard let json = Self.model3DJSONString(
                udid: udid,
                simulators: simulators,
                models: models
            ) else {
                return errorJSON("no 3D model for udid \(udid)", status: .notFound)
            }
            return Response(
                status: .ok,
                headers: [.contentType: "application/json", .cacheControl: "no-cache"],
                body: .init(byteBuffer: ByteBuffer(string: json))
            )
        }

        // One-shot 3D preview. Capture one current frame and run the
        // same DeviceRenderPlan + DeviceRenderer pipeline as the CLI.
        router.post("/simulators/:udid/render-3d.png") {
            [simulators, models, deviceRenderer] r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let udid = Self.udidParam(r)
            guard !udid.isEmpty, let simulator = simulators.find(udid: udid) else {
                return errorJSON("unknown udid: \(udid)", status: .notFound)
            }
            let buffer = try? await r.body.collect(upTo: 64 * 1024)
            let body = buffer.map { Data(buffer: $0) } ?? Data("{}".utf8)
            let options: DeviceRenderOptions
            do {
                options = try DeviceRenderOptions.parsing(
                    json: body.isEmpty ? Data("{}".utf8) : body
                )
            } catch {
                return errorJSON("invalid 3D render options", status: .badRequest)
            }
            let screenImage: Data
            do {
                screenImage = try await ScreenSnapshot.capture(
                    screen: simulator.screen(),
                    quality: 0.95
                )
            } catch {
                return errorJSON("screen capture failed: \(error)", status: .internalServerError)
            }
            guard let sourceSize = Self.imageDimensions(screenImage) else {
                return errorJSON("captured screen image is invalid", status: .internalServerError)
            }
            switch Self.render3D(
                udid: udid,
                options: options,
                screenImage: screenImage,
                sourceSize: sourceSize,
                simulators: simulators,
                models: models,
                renderer: deviceRenderer
            ) {
            case .rendered(let png):
                return Response(
                    status: .ok,
                    headers: [.contentType: "image/png", .cacheControl: "no-cache"],
                    body: .init(byteBuffer: ByteBuffer(data: png))
                )
            case .unknownDevice, .noModel:
                return errorJSON("no 3D model for udid \(udid)", status: .notFound)
            case .invalidConfiguration:
                return errorJSON("invalid model variant or render configuration", status: .badRequest)
            case .failed:
                return errorJSON("3D rendering failed", status: .internalServerError)
            }
        }

        // Device-farm UI — multi-device dashboard. The HTML at /farm
        // is a thin shell that loads its own component scripts from
        // the `farm/` subfolder; sibling assets (CSS + per-component
        // JS) resolve against `/farm/<file>` via the subdirectory
        // routes below. Registered before the catch-all `/:file` so
        // `/farm` doesn't get hijacked.
        router.get("/farm") { _, _ in Self.staticAsset("farm/farm.html") }

        // Static assets in web-root subfolders (`baguette/` SDK,
        // `devices/`, vendored Leaflet, …). Hummingbird's router
        // rejects two placeholder routes that share a path slot with
        // different param names (`/baguette/:file` vs
        // `/baguette/:dir/:file` both bind position 2 but disagree on
        // the name), so each known subdirectory gets its own literal
        // route. The list lives in `staticAssetSubdirectories`;
        // `StaticAssetRoutesTests` pins it against the folders that
        // actually exist under `Resources/Web/`.
        for dir in Self.staticAssetSubdirectories {
            router.get("/\(dir)/:file") { r, _ in
                let name = String(r.uri.path.split(separator: "/").last ?? "")
                    .removingPercentEncoding ?? ""
                return Self.staticAsset("\(dir)/\(name)")
            }
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
                displayQuery: context.request.uri.queryParameters.get("display"),
                simulators: simulators,
                inbound: inbound,
                outbound: outbound
            )
        }

        // Live 3D streams — SceneKit acts as a Screen decorator, so both
        // existing codecs consume the same rendered IOSurfaces.
        router.ws(
            "/simulators/:udid/stream.3d.mjpeg",
            shouldUpgrade: trustedWebSocketUpgrade
        ) { [simulators, models] inbound, outbound, context in
            var query: [String: [String]] = [:]
            for pair in context.request.uri.queryParameters {
                query[String(pair.key), default: []].append(String(pair.value))
            }
            guard let options = try? Device3DStreamOptions.parse(query) else {
                try? await outbound.write(.text(
                    #"{"ok":false,"error":"invalid live 3D stream options"}"#
                ))
                return
            }
            await Self.live3DStreamWS(
                udid: Self.udidParam(context.request),
                format: .mjpeg,
                options: options,
                simulators: simulators,
                models: models,
                inbound: inbound,
                outbound: outbound
            )
        }
        router.ws(
            "/simulators/:udid/stream.3d.avcc",
            shouldUpgrade: trustedWebSocketUpgrade
        ) { [simulators, models] inbound, outbound, context in
            var query: [String: [String]] = [:]
            for pair in context.request.uri.queryParameters {
                query[String(pair.key), default: []].append(String(pair.value))
            }
            guard let options = try? Device3DStreamOptions.parse(query) else {
                try? await outbound.write(.text(
                    #"{"ok":false,"error":"invalid live 3D stream options"}"#
                ))
                return
            }
            await Self.live3DStreamWS(
                udid: Self.udidParam(context.request),
                format: .avcc,
                options: options,
                simulators: simulators,
                models: models,
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

    /// Web-root subfolders that get a literal `/<dir>/:file` route.
    /// Must list every directory under `Resources/Web/` that directly
    /// contains assets — `StaticAssetRoutesTests` checks it against
    /// the folders on disk.
    static let staticAssetSubdirectories = [
        "baguette",
        "baguette/carplay",
        "baguette/gestures",
        "baguette/parts",
        "capture",
        "carplay-frames",
        "carplay-frames/cupra",
        "carplay-frames/plain",
        "devices",
        "farm",
        "network",
        "screens",
        "toolbar",
        "vendor/leaflet",
    ]

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

    /// Outcome of `applyShake` — one case per HTTP-status branch the
    /// shake route maps to.
    enum ShakeOutcome: Equatable {
        case ok
        case unknownDevice
        case dispatchFailed
    }

    /// Pure dispatch for `POST /simulators/:udid/shake`. Split from the
    /// route closure so unit tests can drive every branch
    /// (`MockSimulators` + `MockShake`) without booting Hummingbird.
    static func applyShake(
        udid: String,
        simulators: any Simulators
    ) async -> ShakeOutcome {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            return .unknownDevice
        }
        do {
            try await sim.shake().shake()
            return .ok
        } catch {
            return .dispatchFailed
        }
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

    // MARK: - Location routes

    /// A parsed location request — a single point (`set`), a moving route
    /// (`start`), or the browser joystick's walk vector. The route body is
    /// distinguished by a `waypoints` array and the walk by a `bearing`;
    /// otherwise a bare `latitude`/`longitude` pair is a point.
    enum LocationRequest: Equatable {
        case point(Coordinate)
        case route(LocationRoute)
        case walk(LocationWalk)
    }

    /// Outcome of the location routes — one case per HTTP-status branch.
    enum LocationOutcome: Equatable {
        case ok
        case invalidBody
        case unknownDevice
        case dispatchFailed
    }

    /// Parse a `LocationRequest` from a JSON request body. Returns `nil`
    /// for malformed JSON, an out-of-range point, a route with fewer
    /// than two valid waypoints, or a walk with no positive speed — fail
    /// loud rather than silently dropping it. Numbers arrive as JSON
    /// numbers; `Coordinate` / `LocationRoute` / `LocationWalk` own the
    /// validation.
    ///
    /// Order matters. A walk body carries `latitude`/`longitude` just
    /// like a point does, so `bearing` has to be read *before* the bare
    /// point branch — otherwise every joystick vector would parse as a
    /// stationary point and the device would never move.
    static func parseLocationRequest(json: String) -> LocationRequest? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        if let raw = dict["waypoints"] as? [Any] {
            let coords = raw.compactMap { coordinateFromJSON($0) }
            guard coords.count == raw.count else { return nil }
            guard let route = LocationRoute(
                waypoints: coords,
                speed: doubleField(dict["speed"]),
                distance: doubleField(dict["distance"]),
                interval: doubleField(dict["interval"])
            ) else { return nil }
            return .route(route)
        }
        if let bearing = doubleField(dict["bearing"]) {
            guard let origin = coordinateFromJSON(object),
                  let speed = doubleField(dict["speed"]),
                  let walk = LocationWalk(
                      origin: origin, bearing: Bearing(degrees: bearing), speed: speed
                  ) else { return nil }
            return .walk(walk)
        }
        guard let coordinate = coordinateFromJSON(object) else { return nil }
        return .point(coordinate)
    }

    /// Build a `Coordinate` from a `{"latitude":…,"longitude":…}` JSON
    /// object, validating the range. Returns `nil` for a non-object or an
    /// out-of-range pair.
    private static func coordinateFromJSON(_ value: Any) -> Coordinate? {
        guard let dict = value as? [String: Any],
              let lat = doubleField(dict["latitude"]),
              let lon = doubleField(dict["longitude"]) else {
            return nil
        }
        return Coordinate(latitude: lat, longitude: lon)
    }

    /// JSON numbers arrive as `NSNumber`; accept either a `Double` or an
    /// `Int` spelling so `1` and `1.0` both work.
    private static func doubleField(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    /// Pure parse + dispatch for `POST /simulators/:udid/location`. Split
    /// from the route closure so unit tests can drive every branch with
    /// `MockSimulators` + `MockLocation`.
    ///
    /// When `sessions` carries a **running** motion session for this device,
    /// the same request also drives motion: the browser keeps posting the
    /// walk vector it always did, and the activity follows from its speed.
    /// A session is never created here — motion stays opt-in.
    static func applyLocation(
        udid: String,
        body: String,
        simulators: any Simulators,
        sessions: MotionSessions? = nil
    ) async -> LocationOutcome {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            return .unknownDevice
        }
        guard let request = parseLocationRequest(json: body) else {
            return .invalidBody
        }
        do {
            switch request {
            case .point(let coordinate): try await sim.location().set(coordinate)
            case .route(let route): try await sim.location().start(route)
            // A walk is a route — projected over the horizon along its
            // bearing — so the joystick reuses the `start` path that makes
            // locationd derive course, rather than the `set` path that
            // reports course = -1.
            case .walk(let walk): try await sim.location().start(walk.route())
            }
        } catch {
            return .dispatchFailed
        }
        await driveMotion(with: request, on: sim, sessions: sessions)
        return .ok
    }

    /// The speed a location request moves the device at, which is what
    /// classifies the motion. A pinned point isn't travelling at all —
    /// locationd reports `course = -1` for it — so it parks motion rather
    /// than leaving a stale walk running.
    private static func driveMotion(
        with request: LocationRequest,
        on simulator: any Simulator,
        sessions: MotionSessions?
    ) async {
        guard let sessions else { return }
        guard let session = await sessions.active(udid: simulator.udid) else { return }
        let speed: Double
        switch request {
        case .point: speed = 0
        // An untuned route runs at simctl's own default of 20 m/s, which is
        // motorway-ish — so an untuned route reads as automotive, not as a
        // stroll.
        case .route(let route): speed = route.speed ?? 20
        case .walk(let walk): speed = walk.speed
        }
        await session.drive(speed: speed, on: simulator)
    }

    /// Pure dispatch for `DELETE /simulators/:udid/location`.
    ///
    /// Dropping the location override also parks motion: the device has
    /// stopped being driven anywhere, so an app shouldn't keep reading a
    /// walk.
    static func clearLocation(
        udid: String,
        simulators: any Simulators,
        sessions: MotionSessions? = nil
    ) async -> LocationOutcome {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            return .unknownDevice
        }
        do {
            try await sim.location().clear()
        } catch {
            return .dispatchFailed
        }
        if let session = await sessions?.active(udid: udid) {
            await session.drive(speed: 0, on: sim)
        }
        return .ok
    }

    // MARK: - motion

    /// A parsed `POST /simulators/:udid/motion` body.
    struct MotionRequest: Equatable {
        let kind: MotionKind
        let confidence: MotionConfidence
        let speed: Double
    }

    /// Parse a `MotionRequest` from either spelling:
    ///
    /// - `{"activity":"running"}` — names the kind outright, as the CLI
    ///   does. Its speed defaults to that kind's usual pace.
    /// - `{"speed":6}` — names only how fast the device is moving, as the
    ///   **browser** does, and the kind is classified here.
    ///
    /// The second spelling is what keeps `MotionKind`'s thresholds out of
    /// the frontend: the card posts the speed it's already set to move at,
    /// exactly as it posts walk vectors, and Swift owns the classification.
    /// Two copies of those bands would drift.
    ///
    /// An `activity` that names no real kind is a `400` rather than a
    /// silent `unknown`, which would look like the feature was working.
    static func parseMotionRequest(json: String) -> MotionRequest? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        // A supplied-but-unknown confidence is rejected rather than quietly
        // downgraded to `high` — reporting a confidence nobody asked for is
        // worse than refusing the request.
        let confidence: MotionConfidence
        if let word = dict["confidence"] as? String {
            guard let parsed = MotionConfidence(rawValue: word) else { return nil }
            confidence = parsed
        } else {
            confidence = .high
        }
        // A negative speed classifies as `unknown`, which would arm a session
        // that reports no motion at all — indistinguishable from a broken
        // feature. CoreLocation's "-1 means I don't know" has no meaning as
        // an *instruction*.
        let speed = doubleField(dict["speed"])
        if let speed, speed < 0 { return nil }
        if let activity = dict["activity"] as? String {
            guard let kind = MotionKind(rawValue: activity), kind != .unknown else { return nil }
            return MotionRequest(
                kind: kind, confidence: confidence,
                speed: speed ?? MotionCommand.defaultSpeed(for: kind))
        }
        guard let speed else { return nil }
        return MotionRequest(kind: .from(speed: speed), confidence: confidence, speed: speed)
    }

    /// Pure parse + dispatch for `POST /simulators/:udid/motion` — arms the
    /// dylib and states what the device is doing. Creates the session, so
    /// this is the one place motion turns on.
    static func applyMotion(
        udid: String,
        body: String,
        simulators: any Simulators,
        sessions: MotionSessions
    ) async -> LocationOutcome {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            return .unknownDevice
        }
        guard let request = parseMotionRequest(json: body) else {
            return .invalidBody
        }
        let session = await sessions.session(for: sim)
        await session.set(kind: request.kind, confidence: request.confidence,
                          speed: request.speed, on: sim)
        // Say what was armed. Injection only takes effect on the next app
        // launch, so when someone reports "my app sees nothing" this line is
        // the first thing worth checking.
        if let failure = await session.lastError {
            log("motion: failed to arm \(sim.name) — \(failure)")
            return .dispatchFailed
        }
        log("motion: \(sim.name) is \(request.kind.rawValue) at \(request.speed) m/s")
        return .ok
    }

    /// Pure dispatch for `DELETE /simulators/:udid/motion` — parks the
    /// device as stationary, disarms the dylib, and forgets the session so a
    /// later walk stops driving it.
    static func stopMotion(
        udid: String,
        simulators: any Simulators,
        sessions: MotionSessions
    ) async -> LocationOutcome {
        guard !udid.isEmpty, simulators.find(udid: udid) != nil else {
            return .unknownDevice
        }
        if let session = await sessions.active(udid: udid) {
            // Keep the session when the stop failed, so a retry still has
            // something to disarm — dropping it would strand an armed dylib
            // with nothing tracking it.
            guard await session.stop() else { return .dispatchFailed }
        }
        await sessions.end(udid: udid)
        return .ok
    }

    /// The `{"activity":…,"steps":…}` payload the browser's readout shows, or
    /// `nil` when no such simulator exists — the caller turns that into the
    /// same `404` the POST and DELETE routes give, rather than reporting an
    /// unknown device as one with motion switched off.
    static func motionState(udid: String, simulators: any Simulators,
                            sessions: MotionSessions) async -> String? {
        guard !udid.isEmpty, simulators.find(udid: udid) != nil else { return nil }
        return await motionStateJSON(udid: udid, sessions: sessions)
    }

    static func motionStateJSON(udid: String, sessions: MotionSessions) async -> String {
        guard let session = await sessions.active(udid: udid) else {
            return #"{"ok":true,"active":false}"#
        }
        let kind: String
        switch await session.phase {
        case .idle: kind = MotionKind.stationary.rawValue
        case .publishing(let k): kind = k.rawValue
        }
        let steps = await session.steps
        let metres = await session.metres
        let speed = await session.speed
        return #"{"ok":true,"active":true,"activity":"\#(kind)","steps":\#(steps),"#
            + #""metres":\#(String(format: "%.1f", metres)),"#
            + #""speed":\#(String(format: "%.2f", speed))}"#
    }

    // MARK: - network

    /// Parse a `NetworkCondition` from one of three spellings:
    ///
    /// - `{"profile":"3g"}` — a named preset, resolved here so Network Link
    ///   Conditioner's figures live in Swift alone and never get copied into
    ///   JavaScript where the two would drift.
    /// - `{"latencyMs":300,"bandwidthKbps":400,"lossPercent":5}` — explicit.
    /// - `{"offline":true}`.
    ///
    /// **Exactly one** of those, matching the CLI: "3G but lossier" reads
    /// like it ought to work, and once it does, whether the preset or the
    /// field wins becomes something a caller has to remember. A body that
    /// conditions nothing is a `400` rather than a no-op, because arming
    /// costs an app relaunch and achieving nothing visible would look like
    /// the feature being broken.
    ///
    /// `"offline":false` is *not* a source: the browser card posts its whole
    /// form, so that key arrives alongside real numbers on every ordinary
    /// request, and counting it would make each of those a conflict.
    static func parseNetworkRequest(json: String) -> NetworkCondition? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        let latency = doubleField(dict["latencyMs"])
        let bandwidth = doubleField(dict["bandwidthKbps"])
        let loss = doubleField(dict["lossPercent"])
        let profile = dict["profile"] as? String
        let offline = (dict["offline"] as? Bool) == true
        let namesNumbers = latency != nil || bandwidth != nil || loss != nil

        let sources = [profile != nil, offline, namesNumbers].filter { $0 }.count
        guard sources == 1 else { return nil }

        if let profile { return NetworkProfile(rawValue: profile)?.condition }
        if offline { return .offline }
        return NetworkCondition(
            latencyMs: latency ?? 0, bandwidthKbps: bandwidth, lossPercent: loss ?? 0)
    }

    /// Pure parse + dispatch for `POST /simulators/:udid/network` — arms the
    /// dylib and states how degraded the network is.
    static func applyNetwork(
        udid: String,
        body: String,
        simulators: any Simulators
    ) async -> LocationOutcome {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            return .unknownDevice
        }
        guard let condition = parseNetworkRequest(json: body) else {
            return .invalidBody
        }
        do {
            try await sim.network().apply(condition, on: sim)
        } catch {
            log("network: failed to condition \(sim.name) — \(error)")
            return .dispatchFailed
        }
        // Say what was armed. Injection only takes effect on the next app
        // launch, so when someone reports "my app isn't slow" this line is
        // the first thing worth checking — and when they report the
        // opposite, months later, it's the record that explains why.
        log("network: \(sim.name) is conditioned — \(condition.summary)")
        return .ok
    }

    /// Pure dispatch for `DELETE /simulators/:udid/network`.
    static func clearNetwork(
        udid: String,
        simulators: any Simulators
    ) async -> LocationOutcome {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            return .unknownDevice
        }
        do {
            try await sim.network().clear(on: sim)
        } catch {
            log("network: failed to clear \(sim.name) — \(error)")
            return .dispatchFailed
        }
        return .ok
    }

    /// What the browser card's readout and its armed badge are drawn from.
    ///
    /// Carries the preset names as well as the current condition, so adding
    /// a preset shows up in the UI without a second edit and the figures
    /// behind each name stay in Swift.
    ///
    /// `nil` for a udid that isn't a device — the route answers `404`.
    /// Reporting an unknown device as one with no conditioning would read
    /// as reassurance about a simulator that doesn't exist, which is the
    /// wrong answer to give a badge whose whole job is being believed.
    static func networkStateJSON(udid: String, simulators: any Simulators) async -> String? {
        let profiles = NetworkProfile.allCases
            .map { "\"\($0.rawValue)\"" }
            .joined(separator: ",")
        guard let sim = simulators.find(udid: udid) else { return nil }
        guard let condition = await sim.network().current(on: sim) else {
            return #"{"ok":true,"active":false,"profiles":[\#(profiles)]}"#
        }
        let bandwidth = condition.bandwidthKbps.map { "\($0)" } ?? "null"
        // Naming the preset lets the card keep the pill the user pressed
        // lit, without the frontend holding NLC's figures to recognise the
        // numbers it gets back.
        let profile = NetworkProfile.matching(condition).map { "\"\($0.rawValue)\"" } ?? "null"
        return #"{"ok":true,"active":true,"profile":\#(profile),"#
            + #""latencyMs":\#(condition.latencyMs),"#
            + #""bandwidthKbps":\#(bandwidth),"lossPercent":\#(condition.lossPercent),"#
            + #""offline":\#(condition.isOffline),"summary":"\#(condition.summary)","#
            + #""profiles":[\#(profiles)]}"#
    }

    /// Upper bound on a single drag-and-drop upload, collected into
    /// memory before staging to a temp file. 1 GiB comfortably covers
    /// `.ipa` apps and media clips; this is a localhost dev tool, so a
    /// generous cap is fine.
    static let maxUploadBytes = 1 << 30

    /// Outcome of `POST /simulators/:udid/files`.
    enum AddFileOutcome: Equatable {
        case installed              // an app → simctl install
        case added                  // media → simctl addmedia
        case unsupported(ext: String)
        /// The file has a home on a simulator, just not through *this*
        /// route — an app posted to `/media`, or a photo to `/apps`.
        /// Distinct from `.unsupported` because the fix is different:
        /// use the other endpoint, don't convert the file.
        case wrongKind(ext: String)
        case badArchive(reason: String)   // a zip that isn't a packed .app
        case unknownDevice
        case dispatchFailed
    }

    /// Pure dispatch for `POST /simulators/:udid/files`. The thin
    /// "which collection?" router: classify the already-materialised
    /// file by extension and hand it to the matching device collection.
    /// A file with no home on a simulator is refused (`.unsupported`)
    /// rather than silently dropped. Split from the route closure so
    /// unit tests drive every branch with `MockSimulators` + `MockApps`
    /// / `MockPhotoLibrary`.
    /// The upload plumbing `/files`, `/apps` and `/media` share:
    /// sanitise the client-supplied name, reject an extension with no
    /// home *before* reading megabytes, stage into a unique temp dir,
    /// dispatch, then clean up whatever happened.
    ///
    /// Only `allowing` differs between the three, which is the point —
    /// the routes are the same act under different authority, so they
    /// should not be three copies that can drift apart.
    static func handleUpload(
        _ r: Request, simulators: any Simulators, allowing kinds: UploadKinds
    ) async -> Response {
        let udid = Self.udidParam(r)
        // Strip any path components from the client-supplied name so
        // `?name=../../etc/x` can't escape the temp directory.
        let rawName = String(r.uri.queryParameters.get("name") ?? "upload")
        let filename = (rawName as NSString).lastPathComponent
        let nameURL = URL(fileURLWithPath: filename)

        // Cheap reject before reading the body: if the extension has no
        // home on a simulator — or no home on *this* route — don't
        // bother uploading megabytes to find out.
        let isApp = AppBundle.at(nameURL) != nil || AppArchive.at(nameURL) != nil
        let isMedia = MediaItem.at(nameURL) != nil
        guard isApp || isMedia else {
            return errorJSON(
                "no home for .\(nameURL.pathExtension) on a simulator (apps, zipped apps, and media only)",
                status: .unsupportedMediaType
            )
        }
        guard (isApp && kinds.contains(.apps)) || (isMedia && kinds.contains(.media)) else {
            return errorJSON(Self.wrongKindMessage(ext: nameURL.pathExtension.lowercased(), allowed: kinds),
                             status: .unsupportedMediaType)
        }
        guard let buffer = try? await r.body.collect(upTo: Self.maxUploadBytes) else {
            return errorJSON("upload too large (max \(Self.maxUploadBytes / (1 << 20)) MiB) or unreadable", status: .badRequest)
        }

        // Materialise into a unique temp dir (preserving the name so
        // the extension — and simctl's bundle detection — survives),
        // dispatch, then clean up regardless of outcome.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-upload-\(UUID().uuidString)")
        let tempURL = dir.appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(buffer: buffer).write(to: tempURL)
        } catch {
            return errorJSON("could not stage upload: \(error)", status: .internalServerError)
        }

        switch await Self.addFile(udid: udid, path: tempURL, simulators: simulators, allowing: kinds) {
        case .installed:
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: ByteBuffer(string: "{\"ok\":true,\"kind\":\"app\"}")))
        case .added:
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: ByteBuffer(string: "{\"ok\":true,\"kind\":\"media\"}")))
        case .unsupported(let ext):
            return errorJSON("no home for .\(ext) on a simulator (apps, zipped apps, and media only)", status: .unsupportedMediaType)
        case .wrongKind(let ext):
            return errorJSON(Self.wrongKindMessage(ext: ext, allowed: kinds), status: .unsupportedMediaType)
        case .badArchive(let reason):
            return errorJSON(reason, status: .unsupportedMediaType)
        case .unknownDevice:
            return errorJSON("unknown udid: \(udid)", status: .notFound)
        case .dispatchFailed:
            return errorJSON("file upload failed (simctl error — is the device booted?)", status: .internalServerError)
        }
    }

    /// Names the endpoint that *would* have taken it, so the fix is
    /// obvious rather than "415, good luck".
    static func wrongKindMessage(ext: String, allowed: UploadKinds) -> String {
        allowed.contains(.apps)
            ? ".\(ext) is media, not an app — POST it to /media"
            : ".\(ext) is an app, not media — POST it to /apps"
    }

    static func addFile(
        udid: String,
        path: URL,
        simulators: any Simulators,
        allowing kinds: UploadKinds = .all
    ) async -> AddFileOutcome {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            return .unknownDevice
        }
        do {
            if let app = AppBundle.at(path) {
                guard kinds.contains(.apps) else { return .wrongKind(ext: path.pathExtension.lowercased()) }
                try await sim.apps().install(app)
                return .installed
            }
            if let archive = AppArchive.at(path) {
                guard kinds.contains(.apps) else { return .wrongKind(ext: path.pathExtension.lowercased()) }
                try await sim.apps().install(archive: archive)
                return .installed
            }
            if let media = MediaItem.at(path) {
                guard kinds.contains(.media) else { return .wrongKind(ext: path.pathExtension.lowercased()) }
                try await sim.photos().add(media)
                return .added
            }
            return .unsupported(ext: path.pathExtension.lowercased())
        } catch let error as AppsError {
            // Extraction / locating failures are the upload's fault —
            // surface the reason instead of a generic simctl 500.
            switch error {
            case .extractFailed, .archiveTooLarge, .noAppInArchive:
                return .badArchive(reason: error.description)
            // `openFailed` / `listFailed` can't reach an upload, but the
            // switch has to name them: the compiler is the only thing
            // that will notice when a new `AppsError` case does.
            case .installFailed, .openFailed, .listFailed:
                return .dispatchFailed
            }
        } catch {
            return .dispatchFailed
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

    enum Render3DOutcome: Equatable {
        case rendered(Data)
        case unknownDevice
        case noModel
        case invalidConfiguration
        case failed
    }

    static func render3D(
        udid: String,
        options: DeviceRenderOptions,
        screenImage: Data,
        sourceSize: RenderDimensions,
        simulators: any Simulators,
        models: any DeviceModels,
        renderer: any DeviceRenderer
    ) -> Render3DOutcome {
        guard !udid.isEmpty, let simulator = simulators.find(udid: udid) else {
            return .unknownDevice
        }
        let installed: InstalledDeviceModel
        do {
            guard let model = try simulator.deviceModel(in: models) else {
                return .noModel
            }
            installed = model
        } catch {
            return .noModel
        }
        let plan: DeviceRenderPlan
        do {
            plan = try DeviceRenderPlan.build(
                model: installed,
                variants: options.variants,
                rotation: options.rotation,
                outputSize: options.outputSize(source: sourceSize),
                fit: options.fit,
                background: options.background,
                screenGlass: options.screenGlass
            )
        } catch {
            return .invalidConfiguration
        }
        do {
            return .rendered(try renderer.render(
                plan: plan,
                screenImage: screenImage
            ))
        } catch {
            return .failed
        }
    }

    static func live3DPlan(
        udid: String,
        options: Device3DStreamOptions,
        simulators: any Simulators,
        models: any DeviceModels
    ) throws -> DeviceRenderPlan {
        guard !udid.isEmpty, let simulator = simulators.find(udid: udid) else {
            throw DeviceModelError.modelNotFound(udid)
        }
        guard let installed = try simulator.deviceModel(in: models) else {
            throw DeviceModelError.noModelForDevice(simulator.deviceTypeName)
        }
        return try DeviceRenderPlan.build(
            model: installed,
            variants: options.variants,
            rotation: options.rotation,
            outputSize: options.outputSize,
            fit: options.fit,
            background: options.background,
            screenGlass: options.screenGlass
        )
    }

    static func live3DFormat(pathExtension: String) -> StreamFormat? {
        StreamFormat(rawValue: pathExtension)
    }

    static func handleLive3DControl(
        line: String,
        scene: any DeviceScene
    ) throws -> Bool {
        guard let data = line.data(using: .utf8),
              let camera = try Device3DCamera.parsing(json: data) else {
            return false
        }
        scene.update(camera: camera)
        return true
    }

    /// Where the screen mesh currently lands in the rendered image, so the
    /// browser can map Interact-mode clicks onto the device screen without
    /// ray casting into the GPU scene. Sent once on connect and again after
    /// every `set_3d_camera` update.
    static func screenQuadJSON(_ quad: ScreenQuad) -> String? {
        let object: [String: Any] = [
            "type": "screen_quad",
            "corners": [
                [quad.topLeft.u, quad.topLeft.v],
                [quad.topRight.u, quad.topRight.v],
                [quad.bottomRight.u, quad.bottomRight.v],
                [quad.bottomLeft.u, quad.bottomLeft.v],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func model3DJSONString(
        udid: String,
        simulators: any Simulators,
        models: any DeviceModels
    ) -> String? {
        guard !udid.isEmpty, let simulator = simulators.find(udid: udid),
              let installed = try? simulator.deviceModel(in: models) else {
            return nil
        }
        let definition = installed.definition
        let sets: [[String: Any]] = definition.variantSets.map { set in
            [
                "id": set.id,
                "displayName": set.displayName,
                "default": set.default,
                "choices": set.choices.map { choice -> [String: Any] in
                    var value: [String: Any] = [
                        "id": choice.id,
                        "displayName": choice.displayName,
                    ]
                    if let previewColor = choice.previewColor {
                        value["previewColor"] = previewColor
                    }
                    return value
                },
            ]
        }
        let object: [String: Any] = [
            "id": definition.id.rawValue,
            "displayName": definition.displayName,
            "variantSets": sets,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func imageDimensions(_ image: Data) -> RenderDimensions? {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source, 0, nil
              ) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return RenderDimensions(width: width, height: height)
    }

    // MARK: - sized captures

    /// The encodings the screenshot routes serve. `jpeg` is what
    /// `ScreenSnapshot` already hands back, so it stays the source
    /// format everything else is measured against.
    enum CaptureImageFormat: String, Sendable, Equatable, CaseIterable {
        case jpeg
        case png

        /// What the URL ends in. `.jpg`, not `.jpeg` — that's the
        /// extension the route has always published and the one every
        /// `<img src>` in the tree already points at.
        var pathExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .png:  return "png"
            }
        }

        var contentType: String {
            switch self {
            case .jpeg: return "image/jpeg"
            case .png:  return "image/png"
            }
        }

        /// Uniform type identifier for `CGImageDestination`.
        var utType: String {
            switch self {
            case .jpeg: return "public.jpeg"
            case .png:  return "public.png"
            }
        }

        /// What `?quality=` defaults to on a route serving this format.
        ///
        /// `0.85` for JPEG is the historical default, shared with the
        /// CLI. PNG asks for `1.0` instead because `ScreenSnapshot`
        /// only ever hands back JPEG: a PNG still is a JPEG round-trip
        /// whether the caller wanted one or not, and capturing at
        /// full quality is what keeps that intermediate from showing
        /// up as ringing in something the extension promises is
        /// lossless. It is still not bit-exact — see
        /// `docs/features/screenshot.md`.
        var defaultQuality: Double {
            switch self {
            case .jpeg: return 0.85
            case .png:  return 1.0
            }
        }
    }

    /// The `?size=&fit=&background=` trio every capture route accepts —
    /// the HTTP spelling of the vocabulary `CaptureSize` defines, the
    /// toolbar picker speaks, and `baguette screenshot --size` parses.
    /// One value so the routes can't drift apart on defaults.
    ///
    /// **`fit` here is `CaptureFit`, NOT `DeviceScreenFit`.** The two
    /// enums sit a few hundred lines apart in this file, spell the
    /// same three cases (`contain` / `cover` / `stretch`), and mean
    /// entirely different things: `CaptureFit` places the source
    /// image inside the output *canvas*; `DeviceScreenFit` (the
    /// `render-3d.png` body) places the app screenshot onto the 3D
    /// device's screen *mesh*. They are not interchangeable and must
    /// not be merged.
    struct CaptureOptions: Equatable, Sendable {
        let size: CaptureSize
        let fit: CaptureFit
        let background: DeviceRenderBackground

        /// Today's behaviour, exactly: whatever the framebuffer
        /// already is. `contain` and the white mat only ever show up
        /// once a non-native size is asked for, so the default plan is
        /// an identity by construction and the original bytes survive.
        static let `default` = CaptureOptions(
            size: .native, fit: .contain, background: .color("#ffffff")
        )
    }

    /// A query value baguette refuses to guess at. Rejecting beats
    /// substituting: a marketing shot silently served at the wrong
    /// size is worse than a 400 the caller can read.
    enum CaptureQueryError: Error, Equatable {
        case unknownSize(String)
        case unknownFit(String)
        case unknownBackground(String)

        var message: String {
            switch self {
            case .unknownSize(let spec):
                // Reuse the domain's wording so the CLI, the browser,
                // and the route all name the same catalogue.
                return CaptureSizeError.unknownSize(spec).message
            case .unknownFit(let spec):
                return "Unknown fit '\(spec)'. Expected one of: "
                    + CaptureFit.allCases.map(\.rawValue).joined(separator: " | ")
            case .unknownBackground(let spec):
                return "Unknown background '\(spec)'. Expected 'transparent' or #RRGGBB"
            }
        }
    }

    /// Lift `?size=` / `?fit=` / `?background=` off a request. Kept
    /// separate from the string-taking overload below so the route
    /// closures stay one-liners and the parsing stays unit-testable
    /// without a `Request`.
    ///
    /// No `removingPercentEncoding` here — Hummingbird's `URI` already
    /// percent-decodes query values, and decoding twice turns a value
    /// containing a literal `%` into `nil`, which would silently fall
    /// back to the default instead of the 400 this surface promises.
    static func captureOptions(query request: Request) throws -> CaptureOptions {
        func value(_ key: String) -> String? {
            request.uri.queryParameters.get(key)
        }
        return try captureOptions(
            size: value("size"), fit: value("fit"), background: value("background")
        )
    }

    static func captureOptions(
        size: String?,
        fit: String?,
        background: String?
    ) throws -> CaptureOptions {
        let resolvedSize: CaptureSize
        if let size, !size.isEmpty {
            guard let parsed = try? CaptureSize.parse(size) else {
                throw CaptureQueryError.unknownSize(size)
            }
            resolvedSize = parsed
        } else {
            resolvedSize = .native
        }

        let resolvedFit: CaptureFit
        if let fit, !fit.isEmpty {
            guard let parsed = CaptureFit(rawValue: fit.lowercased()) else {
                throw CaptureQueryError.unknownFit(fit)
            }
            resolvedFit = parsed
        } else {
            resolvedFit = .contain
        }

        return CaptureOptions(
            size: resolvedSize,
            fit: resolvedFit,
            background: try captureBackground(background)
        )
    }

    private static func captureBackground(
        _ raw: String?
    ) throws -> DeviceRenderBackground {
        guard let raw, !raw.isEmpty else { return .color("#ffffff") }
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if text == "transparent" { return .transparent }
        // A literal `#` opens the fragment in a URL, so a hand-written
        // `curl '…?background=#ffffff'` never delivers the hash to us.
        // Accept both spellings and normalise to the `#RRGGBB` the
        // render layer already speaks.
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard digits.count == 6,
              digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw CaptureQueryError.unknownBackground(raw)
        }
        return .color("#\(digits)")
    }

    /// What happened to the captured bytes on the way out.
    enum CaptureOutcome: Equatable {
        /// The capture already is what was asked for. The route hands
        /// the bytes straight through, so the default `screenshot.jpg`
        /// stays byte-for-byte what it has always been.
        case unchanged
        case encoded(Data)
        case failed
    }

    /// Re-encode a captured framebuffer onto the canvas `options` asks
    /// for.
    ///
    /// NOTE: the resize lives here rather than inside
    /// `ScreenSnapshot.capture` deliberately — `--size` is landing on
    /// that helper in parallel, and this route surface has to be
    /// mergeable on its own. Once the capture helper carries the same
    /// knobs, this collapses into it and the duplication goes away.
    static func recapture(
        _ image: Data,
        sourceFormat: CaptureImageFormat,
        format: CaptureImageFormat,
        options: CaptureOptions,
        quality: Double
    ) -> CaptureOutcome {
        if sourceFormat == format, options.size.isNative {
            return .unchanged
        }
        guard let source = decodeImage(image),
              let bytes = encodeCapture(
                  source, options: options, format: format, quality: quality
              ) else {
            return .failed
        }
        return .encoded(bytes)
    }

    /// Where the framebuffer lands inside a rasterized bezel.
    ///
    /// The geometry is `DeviceChrome`'s, read through the same
    /// `buttonMargins` shift `DeviceChromeAssets.layoutJSON` publishes
    /// to the browser — server-side and browser-side composites have
    /// to agree on the cutout, or the two renderings of one device
    /// stop matching.
    struct BezelPlacement: Equatable, Sendable {
        let bezel: ChromeImage
        let screen: Rect
        let cornerRadius: Double
    }

    static func bezelPlacement(
        assets: DeviceChromeAssets,
        withButtons: Bool
    ) -> BezelPlacement {
        // `chrome.screenInsets` are measured against the *bare* device
        // body; the merged canvas grew by `buttonMargins` around it,
        // so only the merged variant shifts.
        let base = assets.chrome.screenRect(in: assets.bareComposite.size)
        let offset = withButtons
            ? Point(x: assets.buttonMargins.left, y: assets.buttonMargins.top)
            : Point(x: 0, y: 0)
        return BezelPlacement(
            bezel: withButtons ? assets.composite : assets.bareComposite,
            screen: Rect(
                origin: Point(
                    x: base.origin.x + offset.x,
                    y: base.origin.y + offset.y
                ),
                size: base.size
            ),
            cornerRadius: assets.chrome.innerCornerRadius
        )
    }

    /// Composite the framebuffer into the device's chrome: bezel
    /// underneath, screen on top, clipped to the screen's inner corner
    /// radius.
    ///
    /// The Z-order is not a preference. Apple's DeviceKit composite
    /// paints an opaque dark "off glass" into the screen cutout,
    /// authored to sit UNDER live content — draw the screen first and
    /// the off-glass buries it.
    ///
    /// Always PNG: the device body has transparent corners and the
    /// mat around it may be transparent too.
    static func bezelCapture(
        screenImage: Data,
        assets: DeviceChromeAssets,
        withButtons: Bool,
        options: CaptureOptions
    ) -> Data? {
        let placement = bezelPlacement(assets: assets, withButtons: withButtons)
        guard placement.screen.size.width > 0, placement.screen.size.height > 0,
              let bezel = decodeImage(placement.bezel.data),
              let screen = decodeImage(screenImage) else {
            return nil
        }
        // DeviceKit chrome geometry is in 1× points; the framebuffer
        // arrives in device pixels (a 6.9" phone captures ~1290 px
        // into a ~430 pt cutout). Compositing at the chrome's own
        // scale would throw that 3× away before `?size=` upscales the
        // remains back — exactly the App Store case this route exists
        // for. So the canvas is sized off the *framebuffer*, and the
        // chrome is what gets resampled. Never below 1×: a heavily
        // `?scale=`d capture must not shrink the bezel with it.
        let scale = max(1, Double(screen.width) / placement.screen.size.width)
        let width = Int((placement.bezel.size.width * scale).rounded())
        let height = Int((placement.bezel.size.height * scale).rounded())
        guard width > 0, height > 0,
              let context = bitmapContext(width: width, height: height) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(bezel, in: CGRect(x: 0, y: 0, width: width, height: height))

        // CoreGraphics is bottom-up; chrome geometry is top-left.
        let cutout = CGRect(
            x: placement.screen.origin.x * scale,
            y: Double(height)
                - (placement.screen.origin.y + placement.screen.size.height) * scale,
            width: placement.screen.size.width * scale,
            height: placement.screen.size.height * scale
        )
        context.saveGState()
        // The corner radius is chrome geometry too, so it rides the
        // same scale as the cutout it rounds.
        let radius = placement.cornerRadius * scale
        context.addPath(CGPath(
            roundedRect: cutout,
            cornerWidth: min(radius, cutout.width / 2),
            cornerHeight: min(radius, cutout.height / 2),
            transform: nil
        ))
        context.clip()
        // Cover-fit inside the cutout via the same placement maths the
        // rest of the vocabulary uses, so a framebuffer whose aspect
        // doesn't match the chrome (rotated device, odd `?scale=`)
        // crops instead of distorting.
        let inner = CaptureSize(
            spec: "cutout",
            label: "cutout",
            kind: .fixed(RenderDimensions(
                width: Int(cutout.width.rounded()),
                height: Int(cutout.height.rounded())
            ))
        ).plan(
            source: RenderDimensions(width: screen.width, height: screen.height),
            fit: .cover
        )
        context.draw(screen, in: CGRect(
            x: cutout.minX + Double(inner.drawX),
            y: cutout.maxY - Double(inner.drawY) - Double(inner.drawHeight),
            width: Double(inner.drawWidth),
            height: Double(inner.drawHeight)
        ))
        context.restoreGState()

        guard let composed = context.makeImage() else { return nil }
        return encodeCapture(composed, options: options, format: .png, quality: 1)
    }

    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Redraw `source` onto the canvas `options` asks for, then encode.
    /// The placement maths belongs to `CapturePlacement` — shared with
    /// the browser composer and the CLI so one size means one thing.
    private static func encodeCapture(
        _ source: CGImage,
        options: CaptureOptions,
        format: CaptureImageFormat,
        quality: Double
    ) -> Data? {
        let sourceSize = RenderDimensions(width: source.width, height: source.height)
        let placement = options.size.plan(source: sourceSize, fit: options.fit)
        guard placement.width > 0, placement.height > 0 else { return nil }
        let image: CGImage
        if placement.isIdentity(for: sourceSize) {
            image = source
        } else {
            // JPEG carries no alpha, so an un-matted transparent
            // canvas flattens to *black* on encode — a mat nobody
            // asked for. Fall back to the white default rather than
            // shipping a black-bordered marketing shot.
            let background: DeviceRenderBackground =
                (format == .jpeg && options.background == .transparent)
                    ? .color("#ffffff")
                    : options.background
            guard let drawn = draw(
                source, into: placement, background: background
            ) else { return nil }
            image = drawn
        }
        return encode(image, format: format, quality: quality)
    }

    private static func draw(
        _ source: CGImage,
        into placement: CapturePlacement,
        background: DeviceRenderBackground
    ) -> CGImage? {
        guard let context = bitmapContext(
            width: placement.width, height: placement.height
        ) else { return nil }
        if case .color(let hex) = background {
            let color = HexColor(hex)
            context.setFillColor(
                red: color.red, green: color.green, blue: color.blue, alpha: 1
            )
            context.fill(CGRect(
                x: 0, y: 0, width: placement.width, height: placement.height
            ))
        }
        context.interpolationQuality = .high
        // `CapturePlacement` is top-left origin; CoreGraphics is not.
        context.draw(source, in: CGRect(
            x: placement.drawX,
            y: placement.height - placement.drawY - placement.drawHeight,
            width: placement.drawWidth,
            height: placement.drawHeight
        ))
        return context.makeImage()
    }

    private static func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    private static func encode(
        _ image: CGImage,
        format: CaptureImageFormat,
        quality: Double
    ) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, format.utType as CFString, 1, nil
        ) else { return nil }
        let properties: CFDictionary? = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    private static func screenshot(
        udid: String,
        quality: Double,
        scale: Int,
        format: CaptureImageFormat,
        options: CaptureOptions,
        simulators: any Simulators
    ) async -> Response {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            return errorJSON("unknown udid: \(udid)", status: .notFound)
        }
        let captured: Data
        do {
            captured = try await ScreenSnapshot.capture(
                screen: sim.screen(),
                quality: quality,
                scale: max(1, scale)
            )
        } catch {
            return errorJSON(String(describing: error), status: .internalServerError)
        }
        let bytes: Data
        switch recapture(
            captured, sourceFormat: .jpeg, format: format,
            options: options, quality: quality
        ) {
        case .unchanged:
            bytes = captured
        case .encoded(let encoded):
            bytes = encoded
        case .failed:
            return errorJSON("capture encoding failed", status: .internalServerError)
        }
        return Response(
            status: .ok,
            headers: [.contentType: format.contentType, .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(data: bytes))
        )
    }

    private static func screenshotBezelPNG(
        udid: String,
        quality: Double,
        scale: Int,
        withButtons: Bool,
        options: CaptureOptions,
        simulators: any Simulators,
        chromes: any Chromes
    ) async -> Response {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            return errorJSON("unknown udid: \(udid)", status: .notFound)
        }
        guard let assets = sim.chrome(in: chromes) else {
            return errorJSON("no bezel for udid \(udid)", status: .notFound)
        }
        let captured: Data
        do {
            captured = try await ScreenSnapshot.capture(
                screen: sim.screen(),
                quality: quality,
                scale: max(1, scale)
            )
        } catch {
            return errorJSON(String(describing: error), status: .internalServerError)
        }
        guard let bytes = bezelCapture(
            screenImage: captured,
            assets: assets,
            withButtons: withButtons,
            options: options
        ) else {
            return errorJSON("bezel composite failed", status: .internalServerError)
        }
        return Response(
            status: .ok,
            headers: [.contentType: "image/png", .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(data: bytes))
        )
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
    ///   1. describe_ui      — needs the AX port + outbound writer
    ///   2. paste            — needs the async Pasteboard + outbound
    ///      writer (replies with a `paste_result` frame)
    ///   3. copy             — ferries the sim pasteboard onto the
    ///      host Mac (replies with a `copy_result` frame)
    ///   4. ReconfigParser   — set_bitrate / set_fps / set_scale
    ///   5. stream verbs     — force_idr / snapshot
    ///   6. GestureDispatcher — tap / swipe / touch1-* / touch2-* /
    ///      button / scroll / pinch / pan / key / type
    /// Lines not matched by any of the above are ignored — same
    /// graceful behaviour the stdin control channel has.
    private static func live3DStreamWS(
        udid: String,
        format: StreamFormat,
        options: Device3DStreamOptions,
        simulators: any Simulators,
        models: any DeviceModels,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            try? await outbound.write(.text(#"{"ok":false,"error":"unknown udid"}"#))
            return
        }
        let plan: DeviceRenderPlan
        let scene: RealityKitDeviceScene
        do {
            plan = try live3DPlan(
                udid: udid,
                options: options,
                simulators: simulators,
                models: models
            )
            scene = try RealityKitDeviceScene(plan: plan)
        } catch {
            try? await outbound.write(.text(
                #"{"ok":false,"error":"\#(jsonEscape(String(describing: error)))"}"#
            ))
            return
        }

        let sink = WebSocketFrameSink(outbound: outbound, format: format)
        let stream = format.makeStream(
            config: .default.with(fps: 20),
            sink: sink,
            quality: 0.7
        )
        // 3D stays phone-only; ignore any display=carplay on these routes.
        let bound: (screen: any Screen, input: any Input)
        do {
            bound = try StreamDisplayPlan.phoneOnly.bind(to: sim)
        } catch {
            try? await outbound.write(.text(
                #"{"ok":false,"error":"\#(jsonEscape(String(describing: error)))"}"#
            ))
            return
        }
        let screen = RenderedScreen(source: bound.screen, scene: scene)
        let input = bound.input
        let pasteboard = sim.pasteboard()
        let dispatcher = GestureDispatcher(input: input)
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
        }

        if let quad = scene.screenQuad, let json = screenQuadJSON(quad) {
            try? await outbound.write(.text(json))
        }

        do {
            for try await frame in inbound {
                guard frame.opcode == .text else { continue }
                let line = String(buffer: frame.data)
                do {
                    if try handleLive3DControl(
                        line: line,
                        scene: scene
                    ) {
                        screen.refresh()
                        if let quad = scene.screenQuad, let json = screenQuadJSON(quad) {
                            try? await outbound.write(.text(json))
                        }
                        continue
                    }
                } catch {
                    try? await outbound.write(.text(
                        #"{"ok":false,"error":"invalid 3D camera"}"#
                    ))
                    continue
                }
                if await handleDescribeUI(line: line, sim: sim, outbound: outbound) {
                    continue
                }
                if let frame = await PasteDispatch.dispatch(
                    line: line, pasteboard: pasteboard, input: input
                ).resultFrame {
                    try? await outbound.write(.text(frame))
                    continue
                }
                if let frame = await CopyDispatch.dispatch(
                    line: line, pasteboard: pasteboard, input: input
                ).resultFrame {
                    try? await outbound.write(.text(frame))
                    continue
                }
                await handleInbound(line: line, stream: stream, dispatcher: dispatcher)
            }
        } catch {
            // socket closed; defer cleans up
        }
    }

    private static func streamWS(
        udid: String,
        format: StreamFormat,
        displayQuery: String?,
        simulators: any Simulators,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            try? await outbound.write(.text(#"{"ok":false,"error":"unknown udid"}"#))
            return
        }

        let displayPlan = StreamDisplayPlan.from(query: displayQuery)
        let bound: (screen: any Screen, input: any Input)
        do {
            bound = try displayPlan.bind(to: sim)
        } catch {
            try? await outbound.write(.text(
                #"{"ok":false,"error":"\#(jsonEscape(String(describing: error)))"}"#
            ))
            return
        }

        let sink = WebSocketFrameSink(outbound: outbound, format: format)
        let stream = format.makeStream(config: .default, sink: sink, quality: 0.5)
        let screen = bound.screen
        // One Input for the whole session — the paste keystroke must
        // reuse the same warmed HID services the gestures ride.
        let input = bound.input
        let pasteboard = sim.pasteboard()
        let dispatcher = GestureDispatcher(input: input)

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
                if let frame = await PasteDispatch.dispatch(
                    line: line, pasteboard: pasteboard, input: input
                ).resultFrame {
                    try? await outbound.write(.text(frame))
                    continue
                }
                if let frame = await CopyDispatch.dispatch(
                    line: line, pasteboard: pasteboard, input: input
                ).resultFrame {
                    try? await outbound.write(.text(frame))
                    continue
                }
                await handleInbound(
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
        let allowedHosts = self.allowedHosts
        let trustedWebSocketUpgrade:
            @Sendable (Request, BasicWebSocketRequestContext) async throws -> RouterShouldUpgrade = {
                request, _ in
                Self.isTrustedBrowserRequest(
                    request, bindHost: bindHost, bindPort: bindPort, allowedHosts: allowedHosts
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
        let allowedHosts = self.allowedHosts
        let trustedWebSocketUpgrade:
            @Sendable (Request, BasicWebSocketRequestContext) async throws -> RouterShouldUpgrade = {
                request, _ in
                Self.isTrustedBrowserRequest(
                    request, bindHost: bindHost, bindPort: bindPort, allowedHosts: allowedHosts
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
            webcam: AVCameraCapture(),
            image: ImageFileCapture(),
            video: VideoFileCapture(),
            sink: sink,
            injection: SimctlSimulatorInjection()
        )

        // Push the initial device list so the picker can render
        // immediately without an extra round-trip.
        await sendDeviceList(cameras: cameras, outbound: outbound)

        // 1-Hz heartbeat: sample FPS off the frame counter and push
        // `camera_state` so the browser's "streaming · X fps" readout
        // updates while frames flow. Detached child task — cancelled
        // during teardown below.
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
            // socket closed; teardown below
        }

        // Teardown, explicitly ordered rather than deferred. `stop()`
        // disarms DYLD_INSERT_LIBRARIES on this sim, so it has to be
        // *awaited* here: fired into a detached task it could land after
        // a reconnecting socket armed the next session and disarm that
        // one instead. Capture must also stop before the staged file is
        // dropped, which is the reverse of what LIFO defers gave us.
        heartbeat.cancel()
        await session.stop()
        // Drop any uploaded image/video source when the socket closes so
        // a stale file can't leak into the next session.
        await CameraSourceStaging.shared.clear(udid: udid)
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
        case .start(let startSource, let flags):
            session.setFlags(flags)
            let source: CameraSource
            switch startSource {
            case .webcam(let uid):
                let devices = await cameras.available()
                guard devices.contains(where: { $0.uid == uid }) else {
                    try? await outbound.write(.text(
                        #"{"type":"camera_state","ok":false,"error":"unknown camera deviceUID"}"#
                    ))
                    return
                }
                source = .device(uid: uid)
            case .image, .video:
                guard let path = CameraSourceStaging.shared.path(udid: sim.udid) else {
                    try? await outbound.write(.text(
                        #"{"type":"camera_state","ok":false,"error":"no file uploaded — drop an image or video on the camera card first"}"#
                    ))
                    return
                }
                // Guard against a start that names a different kind than
                // the staged file (e.g. an image staged, "video" started).
                let stagedKind = CameraMediaKind.at(URL(fileURLWithPath: path))
                let wantImage = (startSource == .image)
                guard stagedKind == (wantImage ? .image : .video) else {
                    try? await outbound.write(.text(
                        #"{"type":"camera_state","ok":false,"error":"the uploaded file doesn't match the selected source kind"}"#
                    ))
                    return
                }
                source = wantImage ? .image(path: path) : .video(path: path)
            }
            guard let dylibPath = InjectedDylibInstaller.installIfNeeded(.camera) else {
                try? await outbound.write(.text(
                    #"{"type":"camera_state","ok":false,"error":"VirtualCamera.dylib is not bundled in this build"}"#
                ))
                return
            }
            await session.start(source: source, on: sim, dylibPath: dylibPath)
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
        var sourceKind: String? = nil
        var deviceUID: String? = nil
        if case .streaming(let source) = session.phase {
            phase = "streaming"
            sourceKind = source.wireKind
            if case .device(let uid) = source { deviceUID = uid }
        } else {
            phase = "idle"
        }
        var payload: [String: Any] = [
            "type": "camera_state",
            "ok": session.lastError == nil,
            "phase": phase,
            "fps": session.fps,
        ]
        if let kind = sourceKind { payload["source"] = kind }
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
    ///
    /// The gesture leg hops to `MainActor` because
    /// `IndigoHIDMessageForMouseNSEvent` reads AppKit / NSEvent
    /// thread-local state, and this runs on a NIO event-loop thread —
    /// which builds malformed messages the simulator silently drops.
    /// `ServerPluginRoutes.dispatchInput` has always done this for the
    /// `POST …/input` route; the stream socket is the path the browser's
    /// two-finger gestures actually ride, and it was dispatching raw.
    /// Only stream config and format verbs stay off the hop — they
    /// touch no AppKit state.
    private static func handleInbound(
        line: String,
        stream: any Stream,
        dispatcher: GestureDispatcher
    ) async {
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
        _ = await MainActor.run { dispatcher.dispatch(line: line) }
    }

    /// Pull the UDID out of a `/simulators/<udid>/<verb>` request.
    /// `<verb>` is the last segment, `<udid>` the one before.
    static func udidParam(_ request: Request) -> String {
        udid(inPath: request.uri.path)
    }

    /// The positional rule every `/simulators/:udid/<verb>` route obeys,
    /// as a pure function so routes can be pinned against it in tests.
    ///
    /// Positional rather than read from the router's parameters, which
    /// is why the rule is worth stating out loud: a route that puts the
    /// udid anywhere but second-to-last still compiles, still matches,
    /// and then answers "unknown udid: <whatever segment landed there>".
    static func udid(inPath path: String) -> String {
        let parts = path.split(separator: "/")
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
        bindPort: Int,
        allowedHosts: Set<String> = []
    ) -> Response? {
        guard !isTrustedBrowserRequest(
            request, bindHost: bindHost, bindPort: bindPort, allowedHosts: allowedHosts
        ) else {
            return nil
        }
        return errorJSON("forbidden origin", status: .forbidden)
    }

    /// Browsers can drive localhost services from another site unless the
    /// service checks `Origin`. For a loopback bind, also reject DNS-rebind
    /// style `Host` values that are not loopback names.
    ///
    /// Hosts in `allowedHosts` (exact or `*.suffix`) are trusted as
    /// request Hosts and as browser Origins regardless of port, for
    /// serving behind a reverse proxy.
    static func isTrustedBrowserRequest(
        _ request: Request,
        bindHost: String,
        bindPort: Int,
        allowedHosts: Set<String> = []
    ) -> Bool {
        if isLoopbackBind(bindHost),
           let authority = request.head.authority,
           let requestHost = parseAuthority(authority)?.host,
           !isLoopbackHost(requestHost),
           !isAllowedHost(requestHost, allowedHosts) {
            return false
        }

        // An operator-trusted Origin is accepted outright, including from
        // another site (a web app driving the API cross-origin).
        if let origin = request.headers[.origin],
           let originHost = URLComponents(string: origin)?.host,
           isAllowedHost(originHost, allowedHosts) {
            return true
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

    /// The Origin to reflect in CORS headers, or nil when it isn't an
    /// allowed host. Lets a trusted cross-origin web app read API
    /// responses with credentialed fetches.
    static func corsAllowedOrigin(_ origin: String?, allowedHosts: Set<String>) -> String? {
        guard let origin,
              let host = URLComponents(string: origin)?.host,
              isAllowedHost(host, allowedHosts) else { return nil }
        return origin
    }

    /// The response for a CORS preflight from an allowed-host Origin,
    /// or nil when the request is not such a preflight.
    static func corsPreflightResponse(_ request: Request, allowedHosts: Set<String>) -> Response? {
        guard request.method == .options,
              let origin = corsAllowedOrigin(request.headers[.origin], allowedHosts: allowedHosts),
              let method = request.headers[.accessControlRequestMethod] else { return nil }
        var headers: HTTPFields = [
            .accessControlAllowOrigin: origin,
            .accessControlAllowCredentials: "true",
            .accessControlAllowMethods: method,
            .vary: "Origin",
        ]
        if let requested = request.headers[.accessControlRequestHeaders] {
            headers[.accessControlAllowHeaders] = requested
        }
        return Response(status: .noContent, headers: headers)
    }

    private static func isAllowedHost(_ host: String, _ allowedHosts: Set<String>) -> Bool {
        let lower = host.lowercased()
        if allowedHosts.contains(lower) { return true }
        return allowedHosts.contains {
            $0.hasPrefix("*.") && lower.hasSuffix($0.dropFirst())
        }
    }

    /// Refuses a plugin any route its manifest didn't declare.
    ///
    /// In front of every route on purpose. The alternative — each
    /// handler remembering to ask — is how `screenshot`, `logs`,
    /// `status-bar`, `location`, `files` and `simulators` ended up
    /// declarable but unchecked: the capability existed, the question
    /// was never asked, and the manifest was documentation pretending to
    /// be a rule. Here the question is asked once and a route that
    /// nobody mapped is refused rather than allowed.
    ///
    /// Only requests that present a grant are affected. Everything else
    /// passes straight through to the per-route origin checks, so the
    /// browser and `curl` behave exactly as they did before.
    struct PluginGrantMiddleware<Context: RequestContext>: RouterMiddleware {
        let grants: PluginGrants

        func handle(
            _ request: Request,
            context: Context,
            next: (Request, Context) async throws -> Response
        ) async throws -> Response {
            let presented = request.headers[HTTPField.Name("X-Baguette-Token")!]
            switch PluginAccess.decide(
                token: presented, path: request.uri.path, grants: grants
            ) {
            case .anonymous, .granted:
                return try await next(request, context)
            case .refused(let message):
                return Server.pluginError(message, status: .forbidden)
            }
        }
    }

    /// Reflects allowed-host Origins in CORS response headers, and answers
    /// their preflights, so a trusted web app on another origin can call
    /// the API with credentialed fetches.
    struct AllowedHostsCORSMiddleware<Context: RequestContext>: RouterMiddleware {
        let allowedHosts: Set<String>

        func handle(
            _ request: Request,
            context: Context,
            next: (Request, Context) async throws -> Response
        ) async throws -> Response {
            if let preflight = Server.corsPreflightResponse(request, allowedHosts: allowedHosts) {
                return preflight
            }
            var response = try await next(request, context)
            if let origin = Server.corsAllowedOrigin(request.headers[.origin], allowedHosts: allowedHosts) {
                response.headers[.accessControlAllowOrigin] = origin
                response.headers[.accessControlAllowCredentials] = "true"
                response.headers[.vary] = "Origin"
            }
            return response
        }
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
