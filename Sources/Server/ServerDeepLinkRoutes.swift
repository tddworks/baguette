import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// The two deep-link routes, kept out of `Server.swift`'s main body
/// alongside `ServerPluginRoutes` / `ServerBakeryRoutes` — that file's
/// router-builder inference already grinds when too many closures share
/// one function, and these are independently testable anyway.
///
/// Both are **plugin-reachable** (`PluginCapability.openURL`), which is
/// what lets the deep-link plugin drive them instead of shelling out to
/// `simctl` behind baguette's back. So each accepts either a trusted
/// browser or a live capability grant, exactly as `describe-ui.json` and
/// `input` do.
extension Server {

    // MARK: - registration

    /// `POST /devices/:udid/openurl?url=<encoded>`  open a deep link
    /// `GET  /devices/:udid/schemes.json[?q=…]`     ranked completions
    ///
    /// Ranking happens server-side so there is one ordering rule, tested
    /// once, rather than a JS copy that drifts. `schemes.json` carries
    /// the extension because it answers JSON to a `GET`, matching
    /// `describe-ui.json` / `interface.json` / `simulators.json`.
    func registerDeepLinkRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?
    ) {
        let devices = allDevices

        for path in Self.deviceRoutes("openurl") {
            router.post(RouterPath(path)) { r, _ in
                if Self.presentsGrant(r) == false, let rejected = rejectUntrustedBrowser(r) {
                    return rejected
                }
                let url = r.uri.queryParameters.get("url").map { String($0) } ?? ""
                switch await Self.openURL(
                    udid: Self.udidParam(r), url: url, devices: devices
                ) {
                case .opened(let routing):
                    return Self.deepLinkJSON(Self.openedJSONString(routing: routing))
                case .notAURL:
                    return Self.pluginError(
                        "not a URL (expected a scheme, e.g. myapp://path)", status: .badRequest
                    )
                case .unknownDevice:
                    return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                case .refused(let refusal):
                    return Self.refusal(refusal)
                case .dispatchFailed:
                    return Self.pluginError(
                        "xcrun simctl openurl failed", status: .internalServerError
                    )
                }
            }
        }

        for path in Self.deviceRoutes("schemes.json") {
            router.get(RouterPath(path)) { r, _ in
                if Self.presentsGrant(r) == false, let rejected = rejectUntrustedBrowser(r) {
                    return rejected
                }
                let query = r.uri.queryParameters.get("q").map { String($0) } ?? ""
                switch await Self.schemes(
                    udid: Self.udidParam(r), query: query, devices: devices
                ) {
                case .ok(let suggestions):
                    return Self.deepLinkJSON(Self.schemesJSONString(suggestions))
                case .unknownDevice:
                    return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                case .refused(let refusal):
                    return Self.refusal(refusal)
                case .listFailed:
                    return Self.pluginError(
                        "xcrun simctl listapps failed", status: .internalServerError
                    )
                }
            }
        }
    }

    static func deepLinkJSON(_ body: String) -> Response {
        Response(
            status: .ok,
            headers: [.contentType: "application/json", .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(string: body))
        )
    }

    // MARK: - openurl

    /// Outcome of the openurl route. `.opened` carries **where the link
    /// went**, not merely that dispatch worked: an https link dispatches
    /// happily and then lands in Safari, so a bare "ok" would be a lie
    /// the caller repeats back to the developer.
    enum OpenURLOutcome: Equatable {
        case opened(routing: DeepLink.Routing)
        case notAURL
        case unknownDevice
        case refused(DeviceError)
        case dispatchFailed
    }

    /// Parse the typed text, look up the device, open the link. Split
    /// out from the route closure so unit tests can drive every branch
    /// (one device's `MockApps`) without booting Hummingbird.
    ///
    /// Parsing runs **before** the device lookup: "profile" isn't a URL
    /// whichever device you aim it at, and saying so is more useful than
    /// blaming a udid that may be perfectly fine.
    static func openURL(
        udid: String,
        url: String,
        devices: any Devices
    ) async -> OpenURLOutcome {
        guard let link = DeepLink.from(url) else { return .notAURL }
        let apps: any Apps
        switch role(.apps, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let role): apps = role
        }
        do {
            try await apps.open(link)
        } catch {
            return .dispatchFailed
        }
        return .opened(routing: link.routing)
    }

    /// What a caller gets back from a successful open. The warning copy
    /// lives here rather than in the plugin or the page so there's one
    /// explanation of the Safari fallback, not a server copy and a
    /// drifting client copy.
    static func openedJSONString(routing: DeepLink.Routing) -> String {
        switch routing {
        case .app:
            return #"{"ok":true,"routing":"app"}"#
        case .browser:
            let warning = "This lands in Safari on the simulator, not your app. "
                + "If an app claims the domain, iOS shows an \"Open in …?\" dialog "
                + "that needs a tap, so it never completes unattended. "
                + "Use the app's own scheme for an automated check."
            let encoded = (try? JSONSerialization.data(
                withJSONObject: ["ok": true, "routing": "browser", "warning": warning],
                options: [.sortedKeys]
            )).map { String(decoding: $0, as: UTF8.self) }
            return encoded ?? #"{"ok":true,"routing":"browser"}"#
        }
    }

    // MARK: - schemes.json

    /// Outcome of the scheme-completion route.
    enum SchemesOutcome: Equatable {
        case ok([SchemeSuggestion])
        case unknownDevice
        case refused(DeviceError)
        case listFailed
    }

    /// The completion inventory for what's been typed so far. Ranking
    /// happens here rather than in the caller so there's one ordering
    /// rule, tested once, instead of a copy that drifts.
    static func schemes(
        udid: String,
        query: String,
        devices: any Devices
    ) async -> SchemesOutcome {
        let apps: any Apps
        switch role(.apps, of: udid, in: devices) {
        case .unknownDevice: return .unknownDevice
        case .refused(let refusal): return .refused(refusal)
        case .role(let role): apps = role
        }
        do {
            let installed = try await apps.installed()
            return .ok(SchemeSuggestion.matching(query, in: installed))
        } catch {
            return .listFailed
        }
    }

    /// The inventory as a caller consumes it — one row per suggestion,
    /// already ranked, carrying everything a row renders.
    static func schemesJSONString(_ suggestions: [SchemeSuggestion]) -> String {
        let rows = suggestions.map {
            [
                "scheme": $0.scheme,
                "completion": $0.completion,
                "app": $0.appName,
                "bundleId": $0.bundleIdentifier,
            ]
        }
        let encoded = (try? JSONSerialization.data(
            withJSONObject: ["schemes": rows], options: [.sortedKeys]
        )).map { String(decoding: $0, as: UTF8.self) }
        return encoded ?? #"{"schemes":[]}"#
    }
}
