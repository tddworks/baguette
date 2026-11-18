import BaguetteDevice
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
///   WS   /devices/:udid/companion/video     → companion app video ingest
///   WS   /devices/:udid/companion/motion    → companion app attitude ingest
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

    /// The one owner of the host-wide camera frame buffer. A reference
    /// type for the same reason as `motionSessions`: a failed cleanup
    /// must survive the socket that started it.
    let cameraSessions: CameraSessions

    /// Device-twin state: connected companions and their per-device
    /// video ingest hubs. Reference types for the same reason as
    /// `motionSessions` — membership and decoder sessions must
    /// survive between socket connections.
    let devices: LiveCompanionPhones
    let twinScreens: TwinScreens
    let twinPoses: TwinPoses
    /// Every physical device the `/devices/…` page can show — a view of
    /// `allDevices`, never a second list.
    let physicalDevices: any Devices
    /// Every device of every kind — what `/devices/:udid/…` resolves. Listed
    /// by `DeviceKinds`, outside the server.
    let allDevices: any Devices

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
        cameraSessions: CameraSessions = CameraSessions(guestTerminated: { _ in false }),
        devices: LiveCompanionPhones = LiveCompanionPhones(),
        twinScreens: TwinScreens = TwinScreens(),
        twinPoses: TwinPoses = TwinPoses(),
        allDevices: any Devices
    ) {
        self.simulators = simulators
        self.motionSessions = motionSessions
        self.cameraSessions = cameraSessions
        self.devices = devices
        self.twinScreens = twinScreens
        self.twinPoses = twinPoses
        self.allDevices = allDevices
        self.physicalDevices = allDevices.physical
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
        router.add(middleware: SimulatorTreeDeprecation())
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
        registerScreenStateRoutes(on: router, rejectUntrustedBrowser: rejectUntrustedBrowser)
        registerPowerRoutes(on: router, rejectUntrustedBrowser: rejectUntrustedBrowser)
        registerDeviceListingRoute(on: router, rejectUntrustedBrowser: rejectUntrustedBrowser)
        registerPlaceRoutes(on: router, rejectUntrustedBrowser: rejectUntrustedBrowser)
        registerFileRoutes(on: router, rejectUntrustedBrowser: rejectUntrustedBrowser)
        registerHingeRoutes(on: router, rejectUntrustedBrowser: rejectUntrustedBrowser)
        registerCompanionScreenRoutes(on: router, rejectUntrustedBrowser: rejectUntrustedBrowser)
        registerDeepLinkRoutes(on: router, rejectUntrustedBrowser: rejectUntrustedBrowser)
        registerNotifyRoutes(on: router, rejectUntrustedBrowser: rejectUntrustedBrowser)
        registerDefaultsRoutes(on: router, rejectUntrustedBrowser: rejectUntrustedBrowser)
        registerDeviceTwinRoutes(
            on: router,
            rejectUntrustedBrowser: rejectUntrustedBrowser,
            trustedWebSocketUpgrade: trustedWebSocketUpgrade
        )

        // Chrome / bezel — DeviceKit-sourced layout + rasterized PNG, for
        // any device by its model, under both trees. Each answers with
        // URLs on the tree it was asked on.
        let devices = allDevices
        for path in Self.deviceRoutes("chrome.json") {
            router.get(RouterPath(path)) { [chromes] r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                return Self.chromeJSON(
                    udid: Self.udidParam(r), devices: devices, chromes: chromes, tree: Self.tree(of: r))
            }
        }
        // SDK bootstrap — the single endpoint `Baguette.use(udid)` hits to
        // instantiate the JS-side device facade: the device's own chrome,
        // or the one a phone borrows with `?chrome=`.
        for path in Self.deviceRoutes("definition.json") {
            router.get(RouterPath(path)) { [chromes] r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                return Self.definitionResponse(
                    udid: Self.udidParam(r), tree: Self.tree(of: r),
                    picked: r.uri.queryParameters.get("chrome").map { String($0) },
                    panel: Self.panelQuery(r.uri.queryParameters.get("panel").map { String($0) }),
                    devices: devices, chromes: chromes)
            }
        }
        // The lit panel's framebuffer mask — the shape the device clips
        // that screen to. 404 when the chrome names none; the page then
        // rounds by `clipRadius` as it always has.
        for path in Self.deviceRoutes("screen-mask.png") {
            router.get(RouterPath(path)) { [chromes] r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                guard let bytes = Self.screenMaskImage(
                    udid: Self.udidParam(r), devices: devices, chromes: chromes,
                    panel: Self.panelQuery(r.uri.queryParameters.get("panel").map { String($0) })
                ) else {
                    return Response(
                        status: .notFound,
                        headers: [.contentType: "text/plain"],
                        body: .init(byteBuffer: ByteBuffer(string: "no screen mask for \(Self.udidParam(r))"))
                    )
                }
                return Response(
                    status: .ok,
                    headers: [.contentType: "image/png", .cacheControl: "no-cache"],
                    body: .init(byteBuffer: ByteBuffer(data: bytes))
                )
            }
        }
        // ?buttons=false → bare device body (no buttons baked in); the
        // actionable-bezel front end layers per-button images on top via
        // the chrome-button route below. Default (true) is the merged
        // composite.
        for path in Self.deviceRoutes("bezel.png") {
            router.get(RouterPath(path)) { [chromes] r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                let withButtons = r.uri.queryParameters.get("buttons")
                    .map { $0.lowercased() != "false" } ?? true
                return Self.bezelPNG(
                    udid: Self.udidParam(r),
                    devices: devices,
                    chromes: chromes,
                    withButtons: withButtons,
                    panel: Self.panelQuery(r.uri.queryParameters.get("panel").map { String($0) })
                )
            }
        }
        // Per-button rasterized PNG — feeds the actionable-bezel UI.
        // `:file` is the last URL segment, typically `<name>.png` matching
        // a `ChromeButton.name` in `chrome.json`. Registered before the
        // catch-all `/:file` so the longer template wins. The udid is the
        // second segment here (`parts[1]`), not the second-to-last.
        for path in Self.chromeButtonRoutes {
            router.get(RouterPath(path)) { [chromes] r, _ in
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
                    devices: devices,
                    chromes: chromes,
                    panel: Self.panelQuery(r.uri.queryParameters.get("panel").map { String($0) })
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
        for path in Self.deviceRoutes("screenshot-bezel.png") {
            router.get(RouterPath(path)) { [chromes] r, _ in
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
                    devices: devices,
                    chromes: chromes
                )
            }
        }

        // Data-driven 3D model metadata for the focus-mode inspector.
        // Only public IDs / labels / preview colors cross this boundary;
        // raw USD paths and variant names remain server-side.
        // Its 3D model, for any device, under both trees. Matched → the
        // model's public ids and choices. A phone with none matched gets the
        // installed models as choices instead, because baguette never
        // silently substitutes a look-alike: the user picks, and the pick
        // rides `?model=` on the 3D socket.
        for path in Self.deviceRoutes("3d-model.json") {
            router.get(RouterPath(path)) { [models] r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                return Self.model3DResponse(udid: Self.udidParam(r), devices: devices, models: models)
            }
        }

        // One-shot 3D preview. Capture one current frame and run the
        // same DeviceRenderPlan + DeviceRenderer pipeline as the CLI.
        for path in Self.deviceRoutes("render-3d.png") {
            router.post(RouterPath(path)) { [models, deviceRenderer] r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                let udid = Self.udidParam(r)
                let screen: any Screen
                switch Self.role(.screen, of: udid, in: devices) {
                case .unknownDevice: return errorJSON("unknown udid: \(udid)", status: .notFound)
                case .refused(let refusal): return Self.refusal(refusal)
                case .role(let role): screen = role
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
                        screen: screen,
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
                    devices: devices,
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
        ) { [allDevices, chromes] inbound, outbound, context in
            await Self.deviceStream(
                context.request, devices: allDevices, chromes: chromes,
                inbound: inbound, outbound: outbound)
        }

        // Live 3D streams — SceneKit acts as a Screen decorator, so both
        // existing codecs consume the same rendered IOSurfaces.
        router.ws(
            "/simulators/:udid/stream.3d.mjpeg",
            shouldUpgrade: trustedWebSocketUpgrade
        ) { [models, allDevices] inbound, outbound, context in
            await Self.deviceLive3D(
                context.request, format: .mjpeg, devices: allDevices, models: models,
                inbound: inbound, outbound: outbound)
        }
        router.ws(
            "/simulators/:udid/stream.3d.avcc",
            shouldUpgrade: trustedWebSocketUpgrade
        ) { [models, allDevices] inbound, outbound, context in
            await Self.deviceLive3D(
                context.request, format: .avcc, devices: allDevices, models: models,
                inbound: inbound, outbound: outbound)
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
        // server; closing the socket stops capture and disarms the
        // dylib, and a failed disarm keeps the owner until an explicit
        // stop succeeds. See `ServerCameraRoutes.swift`.
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
        "defaults",
        "sim-list",
        "farm",
        "handheld",
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
    /// `?panel=` on an image route: the panel the definition named.
    /// Anything else is ignored and the hinge decides, as before.
    static func panelQuery(_ raw: String?) -> IntegratedPanel? {
        switch raw {
        case "primary": return .primary
        case "secondary": return .secondary
        default: return nil
        }
    }



    static func hingeCommandMessage(_ error: HingeCommandError) -> String {
        switch error {
        case .missingTarget: return "pose=closed|open|flat or angle=<0-180> is required"
        case .unknownPose(let pose): return "unknown pose \(pose): expected closed, open or flat"
        case .angleOutOfRange: return "angle must be a number from 0 to 180"
        case .invalidDuration: return "duration must be a number of seconds from 0 to 60"
        }
    }

    /// The 3D socket's answer to a `set_pose` it cannot play.
    static func poseErrorFrame(_ error: HingeCommandError) -> String {
        #"{"ok":false,"error":"\#(jsonEscape(hingeCommandMessage(error)))"}"#
    }

    /// One hinge sample as the stream socket pushes it to the page.
    static func hingeMessage(_ angle: HingeAngle) -> String {
        #"{"type":"hinge","angleDegrees":\#(angle.degrees)}"#
    }



    private static func chromeJSON(
        udid: String,
        devices: any Devices,
        chromes: any Chromes,
        tree: String
    ) -> Response {
        guard let json = chromeJSONString(
            udid: udid, devices: devices, chromes: chromes, tree: tree
        ) else {
            return errorJSON("no chrome for udid \(udid)", status: .notFound)
        }
        return Response(
            status: .ok,
            headers: [.contentType: "application/json", .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(string: json))
        )
    }

    /// `GET …/definition.json` on either tree, for any device: its own
    /// chrome by its model, or — for a phone with none bundled — the one
    /// `?chrome=` borrows. Neither → 404 with `needsChrome`, so the page
    /// renders the picker instead of a dead end.
    static func definitionResponse(
        udid: String, tree: String, picked: String?, panel: IntegratedPanel?,
        devices: any Devices, chromes: any Chromes
    ) -> Response {
        let device: any Device
        do {
            device = try devices.device(DeviceID(udid))
        } catch let refusal as DeviceError {
            return refusal == .unknown(id: DeviceID(udid))
                ? errorJSON("no definition for udid \(udid)", status: .notFound)
                : Self.refusal(refusal)
        } catch {
            return errorJSON("no definition for udid \(udid)", status: .notFound)
        }
        if let picked, !picked.isEmpty {
            return borrowedDefinition(of: device, chrome: picked, chromes: chromes)
        }
        guard let json = definitionJSONString(
            udid: udid, devices: devices, chromes: chromes, panel: panel, tree: tree
        ) else {
            return twinJSONResponse(
                ["ok": false, "needsChrome": true, "error": "pick a chrome with ?chrome=<device name>"],
                status: .notFound)
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
        devices: any Devices,
        chromes: any Chromes,
        tree: String = "simulators"
    ) -> String? {
        guard !udid.isEmpty, let device = (try? devices.find(id: DeviceID(udid))) ?? nil,
              let assets = device.chrome(in: chromes) else {
            return nil
        }
        return assets.layoutJSON(
            buttonImageURLPrefix: "/\(tree)/\(udid)/chrome-button/"
        )
    }

    /// Pure data producer for the SDK bootstrap endpoint
    /// `/simulators/<udid>/definition.json`. Composes a
    /// `SimulatorDefinition` and serialises it. The route closure
    /// (`definitionJSON`) wraps the result into a 200/404 response.
    static func definitionJSONString(
        udid: String,
        devices: any Devices,
        chromes: any Chromes,
        panel pinned: IntegratedPanel? = nil,
        tree: String = "simulators"
    ) -> String? {
        guard !udid.isEmpty, let device = (try? devices.find(id: DeviceID(udid))) ?? nil else { return nil }
        // Resolve the panel once: it names the chrome and it says
        // whether the screen is a foldable's creased, unfolded one. A
        // page bringing the other panel in names it; otherwise the hinge.
        let panel = pinned ?? device.litPanel(in: chromes)
        guard let assets = device.chrome(in: chromes, panel: panel) else { return nil }
        let def = SimulatorDefinition.compose(
            identity: SimulatorDefinition.Identity(
                udid: device.id.raw, name: device.name, model: device.kind.model),
            chrome: assets,
            urlPrefix: "/\(tree)/\(udid)",
            panel: panel
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
        devices: any Devices,
        models: any DeviceModels,
        renderer: any DeviceRenderer
    ) -> Render3DOutcome {
        guard !udid.isEmpty, let device = (try? devices.find(id: DeviceID(udid))) ?? nil else {
            return .unknownDevice
        }
        let installed: InstalledDeviceModel
        do {
            guard let model = try device.model3D(in: models) else {
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
        devices: any Devices,
        models: any DeviceModels
    ) throws -> DeviceRenderPlan {
        guard !udid.isEmpty, let device = (try? devices.find(id: DeviceID(udid))) ?? nil else {
            throw DeviceModelError.modelNotFound(udid)
        }
        guard let installed = try device.model3D(in: models) else {
            throw DeviceModelError.noModelForDevice(device.kind.model)
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

    /// A foldable's lit screen as flat pieces — the unfolded panel bends
    /// at the hinge — each with its corners in the framebuffer's order
    /// and the part of the buffer it shows. Sent in `screen_quad`'s
    /// place whenever the pose or the camera changes.
    static func screenPiecesJSON(
        _ pieces: [ScreenPiece], buttons: [ScreenButtonMark] = [], litPanel: IntegratedPanel? = nil,
        pose: FoldablePose? = nil
    ) -> String? {
        var object: [String: Any] = [
            "type": "screen_quad",
            "buttons": buttons.map {
                ["id": $0.id, "at": [$0.at.u, $0.at.v], "control": [$0.control.u, $0.control.v]]
            },
            "pieces": pieces.map { piece -> [String: Any] in
                let q = piece.quad
                return [
                    "corners": [
                        [q.topLeft.u, q.topLeft.v],
                        [q.topRight.u, q.topRight.v],
                        [q.bottomRight.u, q.bottomRight.v],
                        [q.bottomLeft.u, q.bottomLeft.v],
                    ],
                    "u": [piece.u.lowerBound, piece.u.upperBound],
                    "v": [piece.v.lowerBound, piece.v.upperBound],
                ]
            },
        ]
        if let litPanel { object["litPanel"] = litPanel == .primary ? "primary" : "secondary" }
        if let pose { object["pose"] = ["hingeDegrees": pose.hingeDegrees] }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// `screen_quad` for whatever the scene projects: a foldable's pieces
    /// when it has them, else the one quad.
    static func screenPlacementJSON(_ scene: any DeviceScene, pose: FoldablePose? = nil) -> String? {
        if let pieces = scene.screenPieces {
            return screenPiecesJSON(
                pieces, buttons: scene.screenButtons ?? [], litPanel: scene.litPanel, pose: pose)
        }
        if let quad = scene.screenQuad { return screenQuadJSON(quad) }
        return nil
    }

    static func model3DJSONString(
        udid: String,
        devices: any Devices,
        models: any DeviceModels
    ) -> String? {
        guard !udid.isEmpty, let device = (try? devices.find(id: DeviceID(udid))) ?? nil,
              let installed = try? device.model3D(in: models) else {
            return nil
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: model3DJSONObject(definition: installed.definition),
            options: [.sortedKeys]
        ) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The public projection of one model definition — id, display
    /// name, and variant metadata; USD prim paths never leave the
    /// server. Shared by the simulator and device 3d-model routes.
    static func model3DResponse(udid: String, devices: any Devices, models: any DeviceModels) -> Response {
        if let json = model3DJSONString(udid: udid, devices: devices, models: models) {
            return Response(
                status: .ok,
                headers: [.contentType: "application/json", .cacheControl: "no-cache"],
                body: .init(byteBuffer: ByteBuffer(string: json)))
        }
        guard let device = (try? devices.find(id: DeviceID(udid))) ?? nil,
              device.kind.reality == .physical else {
            return errorJSON("no 3D model for udid \(udid)", status: .notFound)
        }
        let choices = ((try? models.all()) ?? []).map { installed in
            ["id": installed.definition.id.rawValue, "displayName": installed.definition.displayName]
        }
        return twinJSONResponse(
            ["model": NSNull(), "hardware": device.kind.hardware ?? device.kind.model, "models": choices],
            status: .ok)
    }

    static func model3DJSONObject(definition: DeviceModelDefinition) -> [String: Any] {
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
        return [
            "id": definition.id.rawValue,
            "displayName": definition.displayName,
            "variantSets": sets,
        ]
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
        /// `docs/features/screenshot/design.md`.
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


    /// A still of `screen`, encoded and sized as asked — whichever device it is.
    static func screenshot(
        of screen: any Screen,
        quality: Double,
        scale: Int,
        format: CaptureImageFormat,
        options: CaptureOptions
    ) async -> Response {
        let captured: Data
        do {
            captured = try await ScreenSnapshot.capture(
                screen: screen,
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
        devices: any Devices,
        chromes: any Chromes
    ) async -> Response {
        let screen: any Screen
        switch role(.screen, of: udid, in: devices) {
        case .unknownDevice: return errorJSON("unknown udid: \(udid)", status: .notFound)
        case .refused(let refusal): return Self.refusal(refusal)
        case .role(let role): screen = role
        }
        guard let device = (try? devices.find(id: DeviceID(udid))) ?? nil, let assets = device.chrome(in: chromes) else {
            return errorJSON("no bezel for udid \(udid)", status: .notFound)
        }
        let captured: Data
        do {
            captured = try await ScreenSnapshot.capture(
                screen: screen,
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
        devices: any Devices,
        chromes: any Chromes,
        withButtons: Bool = true,
        panel: IntegratedPanel? = nil
    ) -> Response {
        guard let bytes = bezelImage(
            udid: udid, devices: devices,
            chromes: chromes, withButtons: withButtons, panel: panel
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
        devices: any Devices,
        chromes: any Chromes,
        withButtons: Bool,
        panel: IntegratedPanel? = nil
    ) -> Data? {
        guard !udid.isEmpty, let device = (try? devices.find(id: DeviceID(udid))) ?? nil,
              let assets = chrome(of: device, in: chromes, panel: panel) else {
            return nil
        }
        return withButtons ? assets.composite.data : assets.bareComposite.data
    }

    /// The named panel's chrome when the URL names one, else the lit
    /// panel's.
    private static func chrome(
        of device: any Device, in chromes: any Chromes, panel: IntegratedPanel?
    ) -> DeviceChromeAssets? {
        if let panel { return device.chrome(in: chromes, panel: panel) }
        return device.chrome(in: chromes)
    }

    /// The bezel a physical device's page frames it in: the one the user
    /// picked (`?chrome=`), else the device's own when a bezel is installed
    /// under its model name, else none — the page then offers the picker.
    /// A device's definition in a bezel it borrows by name — a phone whose
    /// model has no chrome bundled on this Mac. The image URLs carry the
    /// pick in their path, keeping the bezel routes stateless.
    static func borrowedDefinition(of device: any Device, chrome name: String, chromes: any Chromes) -> Response {
        guard let assets = chromes.assets(forDeviceName: name) else {
            return twinJSONResponse(
                ["ok": false, "needsChrome": true, "error": "no chrome named \(name)"], status: .notFound)
        }
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let definition = SimulatorDefinition.compose(
            identity: SimulatorDefinition.Identity(udid: device.id.raw, name: device.name, model: device.kind.model),
            chrome: assets,
            urlPrefix: "/devices/\(device.id.raw)/chrome/\(encodedName)"
        )
        return Response(
            status: .ok,
            headers: [.contentType: "application/json", .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(string: definition.toJSON()))
        )
    }

    static func bezelName(picked: String?, model: String, chromes: any Chromes) -> String? {
        if let picked, !picked.isEmpty { return picked }
        return chromes.assets(forDeviceName: model) == nil ? nil : model
    }

    /// The screen mask of a bezel a physical device borrows, by the
    /// chrome's name — the `/devices/:udid/chrome/:name/screen-mask.png`
    /// the borrowed definition points the screen at. `nil` when the chrome
    /// carries none (the definition then names no mask either).
    static func borrowedScreenMask(named name: String, chromes: any Chromes) -> Data? {
        chromes.assets(forDeviceName: name)?.screenMask?.data
    }

    /// Pure data producer for `screen-mask.png`: the lit panel's mask,
    /// or `nil` when the chrome carries none.
    static func screenMaskImage(
        udid: String,
        devices: any Devices,
        chromes: any Chromes,
        panel: IntegratedPanel? = nil
    ) -> Data? {
        guard !udid.isEmpty, let device = (try? devices.find(id: DeviceID(udid))) ?? nil,
              let assets = chrome(of: device, in: chromes, panel: panel) else {
            return nil
        }
        return assets.screenMask?.data
    }

    private static func chromeButtonPNG(
        udid: String,
        buttonFile: String,
        devices: any Devices,
        chromes: any Chromes,
        panel: IntegratedPanel? = nil
    ) -> Response {
        guard let bytes = chromeButtonImage(
            udid: udid, buttonFile: buttonFile,
            devices: devices, chromes: chromes, panel: panel
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
        devices: any Devices,
        chromes: any Chromes,
        panel: IntegratedPanel? = nil
    ) -> Data? {
        guard !udid.isEmpty, let device = (try? devices.find(id: DeviceID(udid))) ?? nil,
              let assets = chrome(of: device, in: chromes, panel: panel) else {
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
    /// A device's live 3D stage, its options read off the request — the one
    /// 3D stream for every device; `/devices/:udid/stream.3d.*` uses it for
    /// any device that isn't posed by the companion app.
    static func deviceLive3D(
        _ request: Request, format: StreamFormat, devices: any Devices, models: any DeviceModels,
        inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter
    ) async {
        var query: [String: [String]] = [:]
        for pair in request.uri.queryParameters {
            query[String(pair.key), default: []].append(String(pair.value))
        }
        guard let options = try? Device3DStreamOptions.parse(query) else {
            try? await outbound.write(.text(#"{"ok":false,"error":"invalid live 3D stream options"}"#))
            return
        }
        await live3DStreamWS(
            udid: udidParam(request), format: format, options: options,
            devices: devices, models: models, inbound: inbound, outbound: outbound)
    }

    private static func live3DStreamWS(
        udid: String,
        format: StreamFormat,
        options: Device3DStreamOptions,
        devices: any Devices,
        models: any DeviceModels,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        guard !udid.isEmpty, let device = (try? devices.find(id: DeviceID(udid))) ?? nil else {
            try? await outbound.write(.text(#"{"ok":false,"error":"unknown udid"}"#))
            return
        }
        let plan: DeviceRenderPlan
        let scene: RealityKitDeviceScene
        do {
            plan = try live3DPlan(
                udid: udid,
                options: options,
                devices: devices,
                models: models
            )
            scene = try RealityKitDeviceScene(plan: plan)
        } catch {
            try? await outbound.write(.text(
                #"{"ok":false,"error":"\#(jsonEscape(String(describing: error)))"}"#
            ))
            return
        }

        let sink = WebSocketFrameSink(
            outbound: outbound, format: format, preservingDescriptions: !options.frameMetadata
        )
        let stream = format.makeStream(
            config: .default.with(fps: options.frameRate),
            sink: sink,
            quality: 0.7
        )
        // 3D stays phone-only; ignore any display=carplay on these routes.
        let screen: any DeviceFrames
        let input: Abilities?
        let refresh: () -> Void
        var foldable: RenderedFoldable?
        if plan.model.definition.scene.fold != nil {
            // A foldable: both panels on the book's two screens, the
            // hinge posing it; taps follow the lit panel as everywhere.
            let displays: any Displays
            let hinge: any Hinge
            do {
                displays = try device.require(.displays)
                hinge = try device.require(.hinge)
            } catch {
                try? await outbound.write(.text(
                    #"{"ok":false,"error":"\#(jsonEscape(String(describing: error)))"}"#
                ))
                return
            }
            let unfolded = displays.panel(.secondary)
            let cover = displays.panel(.primary)
            let book = RenderedFoldable(
                unfolded: unfolded.screen(), cover: cover.screen(),
                hinge: hinge, scene: scene, fps: options.frameMetadata ? options.frameRate : nil,
                onPose: { pose in
                    // The lit screen moved: tell the page where it is.
                    // Atomic frames carry the placement themselves. The
                    // pose comes in; holding the book here would keep it,
                    // the scene and this socket alive after the close.
                    if !options.frameMetadata, let json = screenPlacementJSON(scene, pose: pose) {
                        Task { try? await outbound.write(.text(json)) }
                    }
                }
            )
            foldable = book
            screen = book
            // The socket outlives a fold; its hinge watch keeps the
            // lit panel each gesture asks for cached.
            input = .input(of: device.name, all: LitPanelInput(displays: displays, hinge: hinge))
            refresh = { book.refresh() }
        } else {
            let bound: (screen: any Screen, input: Abilities?)
            do {
                bound = try StreamDisplayPlan.phoneOnly.bind(to: device)
            } catch {
                try? await outbound.write(.text(
                    #"{"ok":false,"error":"\#(jsonEscape(String(describing: error)))"}"#
                ))
                return
            }
            let rendered = RenderedScreen(
                source: bound.screen, scene: scene, fps: options.frameMetadata ? options.frameRate : nil)
            screen = rendered
            input = bound.input
            refresh = { rendered.refresh() }
        }
        let pasteboard = try? device.require(.pasteboard)
        let accessibility = try? device.require(.accessibility)
        let screenInput = input ?? Abilities(device: device.name)
        let dispatcher = GestureDispatcher(input: screenInput)
        // Atomic frames: a render or encode failure ends the stream with
        // an error rather than leaving a page with stale hit geometry.
        let frameFailure: @Sendable (any Error) -> Void = { error in
            sink.stop()
            screen.stop()
            Task {
                do {
                    try await outbound.write(
                        .text(#"{"ok":false,"error":"\#(jsonEscape(String(describing: error)))"}"#))
                } catch { log("3D stream error delivery failed: \(error)") }
                // Close separately: a failed error write must not leave the
                // socket open on a stream that no longer produces frames.
                do {
                    try await outbound.close(.unexpectedServerError, reason: "3D frame encoding failed")
                } catch { log("3D stream close failed: \(error)") }
            }
        }
        let receiveFrame: @Sendable (Result<DeviceFrame, any Error>) -> Void
        let stopFrames: () -> Void
        if format == .avcc {
            let encoder = DeviceAVCCEncoder(
                config: .default.with(fps: options.frameRate), quality: 0.7,
                deliver: { sink.writeMessage($0) }, onError: frameFailure)
            receiveFrame = { encoder.receive($0) }
            stopFrames = { encoder.stop() }
        } else {
            let jpeg = JPEGEncoder(quality: 0.7)
            let encoder = DeviceFrameEncoder(
                encode: { jpeg.encode($0) }, deliver: { sink.writeMessage($0) }, onError: frameFailure)
            receiveFrame = { encoder.receive($0) }
            stopFrames = { encoder.stop() }
        }
        do {
            if options.frameMetadata {
                try screen.startFrames(onFrame: receiveFrame)
            } else {
                try stream.start(on: screen)
            }
        } catch {
            try? await outbound.write(.text(
                #"{"ok":false,"error":"\#(jsonEscape(String(describing: error)))"}"#
            ))
            return
        }
        defer {
            stopFrames()
            sink.stop()
            if options.frameMetadata { screen.stop() } else { stream.stop() }
        }

        if !options.frameMetadata, let json = screenPlacementJSON(scene, pose: foldable?.pose) {
            try? await outbound.write(.text(json))
        }

        // Pose requests play in the order they came, one at a time: a
        // slider drag sends a burst of them, and detached tasks racing
        // for the motor would leave the hinge wherever the last to win
        // said, not where the thumb stopped. A request the burst has
        // already passed is skipped, so the hinge catches up to the
        // thumb rather than replaying its path.
        final class PoseQueue: @unchecked Sendable {
            private let lock = NSLock()
            private var tail: Task<Void, Never>?
            private var newest = 0
            func enqueue(_ drive: @escaping @Sendable () -> Void) {
                lock.lock()
                newest += 1
                let mine = newest
                let previous = tail
                let task = Task.detached { [self] in
                    await previous?.value
                    let stale = self.lock.withLock { mine != self.newest }
                    if !stale { drive() }
                }
                tail = task
                lock.unlock()
            }
        }
        let poses = PoseQueue()

        do {
            for try await frame in inbound {
                guard frame.opcode == .text else { continue }
                let line = String(buffer: frame.data)
                do {
                    if try handleLive3DControl(
                        line: line,
                        scene: scene
                    ) {
                        refresh()
                        if !options.frameMetadata, let json = screenPlacementJSON(scene, pose: foldable?.pose) {
                            try? await outbound.write(.text(json))
                        }
                        continue
                    }
                    // The pose picker: the device's own hinge is swept
                    // there (a second or so, off this loop); the book
                    // plays the sweep as it goes.
                    if foldable != nil, let pose = try Device3DPose.parsing(json: Data(line.utf8)) {
                        if case .fold(let degrees, let duration) = pose {
                            let target = String(degrees)
                            let over = duration.map { String($0) }
                            poses.enqueue {
                                let outcome = Self.driveHinge(
                                    udid: udid, pose: nil, angle: target, duration: over,
                                    devices: devices)
                                if outcome != .ok { log("hinge: \(outcome)") }
                            }
                        }
                        continue
                    }
                } catch let error as HingeCommandError {
                    try? await outbound.write(.text(Self.poseErrorFrame(error)))
                    continue
                } catch {
                    try? await outbound.write(.text(
                        #"{"ok":false,"error":"invalid 3D camera"}"#
                    ))
                    continue
                }
                if let accessibility, await handleDescribeUI(line: line, accessibility: accessibility, outbound: outbound) {
                    continue
                }
                if let pasteboard, let frame = await PasteDispatch.dispatch(
                    line: line, pasteboard: pasteboard, input: screenInput
                ).resultFrame {
                    try? await outbound.write(.text(frame))
                    continue
                }
                if let pasteboard, let frame = await CopyDispatch.dispatch(
                    line: line, pasteboard: pasteboard, input: screenInput
                ).resultFrame {
                    try? await outbound.write(.text(frame))
                    continue
                }
                // Atomic frames run on a fixed encoder preset that the
                // `stream` controls never reach; say so instead of
                // acknowledging a retune that changed nothing.
                if options.frameMetadata, ReconfigParser.isStreamControl(line) {
                    try? await outbound.write(.text(
                        #"{"ok":false,"error":"stream controls are not available with frameMetadata=1"}"#
                    ))
                    continue
                }
                do {
                    try await handleInbound(line: line, stream: stream, dispatcher: dispatcher, udid: udid)
                } catch {
                    await sink.failAndClose(error)
                    return
                }
            }
        } catch {
            // socket closed; defer cleans up
        }
    }

    /// A device's live stream, its knobs read off the request: `format`,
    /// `display`, `panel`, `requireExistingDisplay`. The one stream for every
    /// device — `/devices/:udid/stream` uses it for any device whose screen
    /// isn't the companion app's video.
    static func deviceStream(
        _ request: Request, devices: any Devices, chromes: any Chromes,
        inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter
    ) async {
        let existingDisplayValues = request.uri.queryParameters
            .filter { $0.key == "requireExistingDisplay" }.map { String($0.value) }
        guard let requireExistingDisplay = try? StreamDisplayPlan.requireExistingDisplay(query: existingDisplayValues)
        else {
            try? await outbound.write(.text(#"{"ok":false,"error":"invalid requireExistingDisplay"}"#))
            return
        }
        await streamWS(
            udid: udidParam(request),
            format: request.uri.queryParameters.get("format")
                .flatMap { StreamFormat(rawValue: $0) } ?? .mjpeg,
            displayQuery: request.uri.queryParameters.get("display"),
            panelQuery: request.uri.queryParameters.get("panel").map { String($0) },
            requireExistingDisplay: requireExistingDisplay,
            devices: devices,
            chromes: chromes,
            inbound: inbound,
            outbound: outbound
        )
    }

    private static func streamWS(
        udid: String,
        format: StreamFormat,
        displayQuery: String?,
        panelQuery: String? = nil,
        requireExistingDisplay: Bool = false,
        devices: any Devices,
        chromes: any Chromes,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        guard !udid.isEmpty, let device = (try? devices.find(id: DeviceID(udid))) ?? nil else {
            try? await outbound.write(.text(#"{"ok":false,"error":"unknown udid"}"#))
            return
        }

        let displayPlan = StreamDisplayPlan.from(
            query: displayQuery, panel: panelQuery, requireExistingDisplay: requireExistingDisplay
        )
        let bound: (screen: any Screen, input: Abilities?)
        do {
            bound = try displayPlan.bind(to: device)
        } catch {
            try? await outbound.write(.text(
                #"{"ok":false,"error":"\#(jsonEscape(String(describing: error)))"}"#
            ))
            return
        }

        // One guest round-trip per attach, off the critical path: if
        // Device Hub has shadowed this device's input surface, every
        // gesture on this socket will ack and land nowhere. Say so.
        if let surface = try? device.require(.inputSurface) {
            Task {
                if await surface.shadowed(),
                   let advisory = DeviceHubAttachment(attached: true).advisory(udid: udid) {
                    warn("[serve] \(advisory)")
                }
            }
        }

        let sink = WebSocketFrameSink(outbound: outbound, format: format)
        let stream = format.makeStream(config: .default, sink: sink, quality: 0.5)
        let screen = bound.screen
        // One input for the whole session — the paste keystroke must
        // reuse the same warmed HID services the gestures ride. A device
        // that takes no touches gets none: each gesture is refused by name.
        let input = bound.input ?? Abilities(device: device.name)
        let pasteboard = try? device.require(.pasteboard)
        let accessibility = try? device.require(.accessibility)
        let dispatcher = GestureDispatcher(input: input)

        do {
            try stream.start(on: screen)
        } catch {
            try? await outbound.write(.text(
                #"{"ok":false,"error":"\#(jsonEscape(String(describing: error)))"}"#
            ))
            return
        }
        // A foldable's hinge rides the same socket: every sample Device
        // Hub sweeps through lands here as `{"type":"hinge",…}`, so the
        // page can draw the fold at the angle the device is at and knows
        // the moment the lit panel is about to change. A phone has no
        // hinge and is not watched.
        let foldable = displayPlan.kind == .phone
            && chromes.panels(forDeviceName: device.kind.model).contains(.secondary)
        let hingeWatch: (any HingeWatch)? = foldable
            ? (try? device.require(.hinge))?.watch { angle in
                Task { try? await outbound.write(.text(Self.hingeMessage(angle))) }
            }
            : nil
        defer {
            hingeWatch?.cancel()
            stream.stop()
            screen.stop()
        }

        do {
            for try await frame in inbound {
                guard frame.opcode == .text else { continue }
                let line = String(buffer: frame.data)
                if let accessibility, await handleDescribeUI(
                    line: line, accessibility: accessibility, outbound: outbound
                ) {
                    continue
                }
                if let pasteboard, let frame = await PasteDispatch.dispatch(
                    line: line, pasteboard: pasteboard, input: input
                ).resultFrame {
                    try? await outbound.write(.text(frame))
                    continue
                }
                if let pasteboard, let frame = await CopyDispatch.dispatch(
                    line: line, pasteboard: pasteboard, input: input
                ).resultFrame {
                    try? await outbound.write(.text(frame))
                    continue
                }
                do {
                    try await handleInbound(
                        line: line,
                        stream: stream,
                        dispatcher: dispatcher,
                        udid: udid
                    )
                } catch {
                    await sink.failAndClose(error)
                    return
                }
            }
        } catch {
            // socket closed; defer cleans up
        }
    }

    /// `describe_ui` text message — needs the device's accessibility
    /// (a simulator's or a phone's) and the outbound writer (to ship the
    /// result back), neither of which `handleInbound` carries. Returns
    /// `true` when the line was a `describe_ui` envelope (handled
    /// or rejected with an error JSON), `false` for any other
    /// shape so the caller falls through to the gesture / reconfig
    /// pipeline.
    static func handleDescribeUI(
        line: String,
        accessibility ax: @autoclosure () -> any Accessibility,
        outbound: WebSocketOutboundWriter
    ) async -> Bool {
        guard let data = line.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (dict["type"] as? String) == "describe_ui" else {
            return false
        }
        let ax = ax()
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
        let devices = allDevices
        for path in Self.deviceRoutes("logs") {
            router.ws(
                RouterPath(path),
                shouldUpgrade: trustedWebSocketUpgrade
            ) { inbound, outbound, context in
                let req = context.request
                let opts = LogsRouteOptions.from(request: req)
                await Self.logsWS(
                    opts: opts,
                    devices: devices,
                    inbound: inbound,
                    outbound: outbound
                )
            }
        }
    }

    /// The frame that stops a logs socket at once — no device has that id,
    /// or the one that does has no log stream — or nil when it can stream.
    static func logsStopped(udid: String, devices: any Devices) -> String? {
        switch role(.logs, of: udid, in: devices) {
        case .role: return nil
        case .unknownDevice: return #"{"type":"log_stopped","reason":"unknown udid"}"#
        case .refused(let refusal):
            return #"{"type":"log_stopped","reason":"\#(jsonEscape(refusal.description))"}"#
        }
    }

    /// Live log-stream over the dedicated `/devices/:udid/logs` (or `/simulators/…`)
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
        devices: any Devices,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        if let stopped = logsStopped(udid: opts.udid, devices: devices) {
            try? await outbound.write(.text(stopped))
            return
        }
        guard case .role(let stream) = role(.logs, of: opts.udid, in: devices) else { return }
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
    /// Throws when the stream rejects a retune; the route then reports
    /// the error on the socket and closes it, because a codec that
    /// refused its configuration cannot keep delivering valid frames.
    private static func handleInbound(
        line: String,
        stream: any Stream,
        dispatcher: GestureDispatcher,
        udid: String
    ) async throws {
        let next = ReconfigParser.apply(line, to: stream.config)
        if next != stream.config {
            try stream.apply(next)
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
        _ = await gestureQueues.run(on: udid) { dispatcher.dispatch(line: line) }
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
func jsonEscape(_ s: String) -> String {
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
