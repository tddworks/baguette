import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// Plugin-facing route helpers, kept out of `Server.swift`'s main body
/// — that file's router-builder inference already grinds when too many
/// closures share one function, and these are independently testable
/// anyway.
extension Server {

    // MARK: - registration

    /// `GET  /plugins.json`                         installed manifests
    /// `POST /plugins/:id/commands/:cmd`            run a contribution
    /// `GET  /devices/:udid/describe-ui.json`    AX tree over HTTP
    ///
    /// The first two are browser-facing and ride the existing
    /// browser-trust check. `describe-ui.json` is one plugins call, so
    /// it also accepts a **capability grant** — a plugin subprocess has
    /// no `Origin` header to be trusted by, and its token carries only
    /// what its manifest declared.
    func registerPluginRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?
    ) {
        let plugins = self.plugins
        let devices = allDevices
        let grants = self.grants
        let origin = "http://\(self.host):\(self.port)"

        router.get("/plugins.json") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let body = (try? plugins.listJSON) ?? #"{"plugins":[]}"#
            return Response(
                status: .ok,
                headers: [.contentType: "application/json", .cacheControl: "no-cache"],
                body: .init(byteBuffer: ByteBuffer(string: body))
            )
        }

        router.post("/plugins/:id/commands/:cmd") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let qualified = Self.qualifiedCommandParam(r)
            // A `rowAction: "run"` click posts the row's own args here.
            // Opening a panel posts nothing, which stays a valid
            // invocation — hence a body that's absent, empty or
            // unparseable all mean "no args" rather than an error.
            let buffer = try? await r.body.collect(upTo: 64 * 1024)
            let args = Self.parseCommandArgs(body: buffer.map { String(buffer: $0) } ?? "")
            let outcome = await Self.runPlugin(
                qualified: qualified,
                context: PluginDispatch.Context(
                    serverURL: origin,
                    udid: r.uri.queryParameters.get("udid").map { String($0) },
                    // Replaced by a per-invocation grant inside dispatch.
                    token: "",
                    args: args
                ),
                plugins: plugins,
                grants: grants
            )
            switch outcome {
            case .ok(let json):
                return Response(
                    status: .ok,
                    headers: [.contentType: "application/json", .cacheControl: "no-cache"],
                    body: .init(byteBuffer: ByteBuffer(string: json))
                )
            case .unknown(let message):
                return Self.pluginError(message, status: .notFound)
            case .failed(let message):
                return Self.pluginError(message, status: .internalServerError)
            }
        }

        // The gesture pipeline over HTTP, so a plugin can drive the
        // device without holding a WebSocket. `input` is the most
        // powerful capability — it can tap through anything — so it is
        // never implied and must be declared.
        for path in Self.deviceRoutes("input") {
            router.post(RouterPath(path)) { r, _ in
                // A plugin's grant was already checked against `input` by
                // `PluginGrantMiddleware`; reaching here means it declared
                // the capability. A caller with no grant still has to be a
                // trusted browser (or a local non-browser client).
                if Self.presentsGrant(r) == false, let rejected = rejectUntrustedBrowser(r) {
                    return rejected
                }
                let buffer = try? await r.body.collect(upTo: 64 * 1024)
                let body = buffer.map { String(buffer: $0) } ?? ""
                switch await Self.dispatchInput(
                    udid: Self.udidParam(r), body: body, devices: devices
                ) {
                case .ok(let ack):
                    return Self.jsonResponse(ack)
                case .unknownDevice:
                    return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                case .refused(let refusal):
                    return Self.refusal(refusal)
                }
            }
        }

        for path in Self.deviceRoutes("describe-ui.json") {
            router.get(RouterPath(path)) { r, _ in
                // Either a trusted browser, or a plugin whose grant carries
                // `describe-ui` — the middleware already turned away one
                // that didn't, even holding a valid token for something else.
                if Self.presentsGrant(r) == false, let rejected = rejectUntrustedBrowser(r) {
                    return rejected
                }
                let udid = Self.udidParam(r)
                let x = r.uri.queryParameters.get("x").flatMap { Double($0) }
                let y = r.uri.queryParameters.get("y").flatMap { Double($0) }
                let point = (x != nil && y != nil) ? Point(x: x!, y: y!) : nil

                switch Self.describeUI(udid: udid, point: point, devices: devices) {
                case .ok(let json):
                    return Response(
                        status: .ok,
                        headers: [.contentType: "application/json", .cacheControl: "no-cache"],
                        body: .init(byteBuffer: ByteBuffer(string: json))
                    )
                case .unknownDevice:
                    return Self.pluginError("unknown udid: \(udid)", status: .notFound)
                case .refused(let refusal):
                    return Self.refusal(refusal)
                case .noData:
                    return Self.pluginError("no accessibility data", status: .ok)
                case .failed(let message):
                    return Self.pluginError(message, status: .internalServerError)
                }
            }
        }
    }

    /// `/plugins/<id>/commands/<cmd>` → `"<id>:<cmd>"`. Parsed off the
    /// path rather than router parameters, matching `udidParam`.
    static func qualifiedCommandParam(_ request: Request) -> String {
        let parts = request.uri.path.split(separator: "/")
        guard parts.count >= 4 else { return "" }
        let id = String(parts[1]).removingPercentEncoding ?? ""
        let command = String(parts[3]).removingPercentEncoding ?? ""
        return "\(id):\(command)"
    }

    /// Pull a `rowAction: "run"` click's arguments off the request body.
    ///
    /// Everything ambiguous means "no args": an absent body (a panel
    /// being opened), an empty object, or JSON we can't read. That's
    /// deliberate — a click that carries nothing is a normal
    /// invocation, not a client error, and the command decides what to
    /// do without arguments.
    static func parseCommandArgs(body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let args = object["args"] as? [String: Any],
              !args.isEmpty
        else { return nil }
        return args
    }

    /// Whether the caller is claiming to be a plugin at all.
    ///
    /// Only ever asked *after* `PluginGrantMiddleware` has run, so a
    /// `true` here means a live grant that already cleared this route —
    /// never an invented token.
    static func presentsGrant(_ request: Request) -> Bool {
        let token = request.headers[HTTPField.Name("X-Baguette-Token")!]
        return !(token ?? "").isEmpty
    }

    /// `{"ok":false,"error":…}` — the shape every plugin-facing route
    /// answers with, so a plugin has exactly one failure branch.
    static func pluginError(_ message: String, status: HTTPResponse.Status) -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json", .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(
                string: #"{"ok":false,"error":"\#(GestureDispatcher.jsonEscape(message))"}"#
            ))
        )
    }

    // MARK: - describe-ui.json

    enum DescribeUIOutcome: Equatable {
        case ok(String)
        case unknownDevice
        case refused(DeviceError)
        /// Nothing is frontmost (SpringBoard idle, boot in progress).
        /// Not an error: the caller should say "nothing to inspect",
        /// not "inspection failed".
        case noData
        case failed(String)
    }

    /// The accessibility tree over plain HTTP.
    ///
    /// `describe_ui` existed only as a WebSocket message on the stream
    /// socket, which put the tree out of reach of any plugin that
    /// isn't a browser. Same logic, addressable by `curl`.
    static func describeUI(
        udid: String, point: Point?, devices: any Devices
    ) -> DescribeUIOutcome {
        let accessibility: any Accessibility
        switch role(.accessibility, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let role): accessibility = role
        }
        do {
            let node = try point.map { try accessibility.describeAt(point: $0) }
                ?? accessibility.describeAll()
            guard let node else { return .noData }
            return .ok(#"{"ok":true,"tree":\#(node.json)}"#)
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: - input

    enum InputOutcome: Equatable {
        /// The dispatcher's own one-line ack — `{"ok":true}` or
        /// `{"ok":false,"error":…}` for a envelope it couldn't parse.
        case ok(String)
        case unknownDevice
        case refused(DeviceError)
    }

    /// Dispatch one gesture envelope, the same JSON the stream socket
    /// and `baguette input` accept.
    ///
    /// Hops to `MainActor` because `IndigoHIDMessageForMouseNSEvent`
    /// reads AppKit / NSEvent thread-local state — building it on a NIO
    /// event-loop thread yields messages the simulator silently drops.
    /// `Server.streamWS` does the same before dispatching.
    static func dispatchInput(
        udid: String, body: String, devices: any Devices
    ) async -> InputOutcome {
        let input: Abilities
        do {
            input = try devices.device(DeviceID(udid)).input()
        } catch DeviceError.unknown {
            return .unknownDevice
        } catch let refusal as DeviceError {
            return .refused(refusal)
        } catch {
            return .unknownDevice
        }
        let ack = await MainActor.run {
            GestureDispatcher(input: input).dispatch(line: body)
        }
        return .ok(ack)
    }

    // MARK: - running a contributed command

    enum PluginRunOutcome: Equatable {
        case ok(String)
        case unknown(String)
        case failed(String)
    }

    static func runPlugin(
        qualified: String,
        context: PluginDispatch.Context,
        plugins: any Plugins,
        grants: PluginGrants? = nil,
        subprocess: @Sendable () -> any Subprocess = { HostSubprocess() }
    ) async -> PluginRunOutcome {
        let outcome = await PluginDispatch.run(
            qualifiedCommand: qualified,
            context: context,
            plugins: plugins,
            grants: grants,
            subprocess: subprocess
        )
        switch outcome {
        case .ok(let result):
            return .ok(result.json)
        case .unknownCommand:
            return .unknown(outcome.errorText ?? "unknown command")
        default:
            return .failed(outcome.errorText ?? "plugin failed")
        }
    }

}

extension PluginResult {
    /// Wire projection for the plugin routes and the CLI.
    var json: String {
        var dict: [String: Any] = ["ok": ok, "rows": rows.map(\.dictionary)]
        if let message { dict["message"] = message }
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

extension ResultRow {
    var dictionary: [String: Any] {
        var out: [String: Any] = ["title": title, "severity": severity.rawValue]
        if let subtitle { out["subtitle"] = subtitle }
        if let copy { out["copy"] = copy }
        if let fill { out["fill"] = fill }
        // Round-tripped verbatim: the browser sends `run` + `args` back
        // to the command that authored them. baguette is the postman.
        if let run { out["run"] = run }
        if let args { out["args"] = args.object }
        // Absent on a plain row, so a panel that ships no controls
        // projects exactly as it did before controls existed.
        if let state { out["state"] = state.rawValue }
        if let value { out["value"] = value }
        if let group { out["group"] = group }
        if let frame {
            out["frame"] = [
                "x": frame.origin.x, "y": frame.origin.y,
                "width": frame.size.width, "height": frame.size.height,
            ]
        }
        return out
    }
}
