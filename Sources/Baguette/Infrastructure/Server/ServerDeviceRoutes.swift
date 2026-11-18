import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// What every per-device route shares as it moves from `Simulators` to
/// `Devices`: its two spellings, how it finds the role it acts with, and
/// how a refusal answers.
extension Server {

    /// Each device's gesture lane, shared by every way in — the stream
    /// sockets, `POST …/input` — so its gestures land one at a time, in the
    /// order sent, and two devices never wait on each other.
    static let gestureQueues = GestureQueues()

    /// A per-device route's paths: `/devices/:udid/<leaf>` for any device,
    /// and `/simulators/:udid/<leaf>`, the old spelling the page and
    /// plugins still use. The udid stays second-to-last in both, as
    /// `udid(inPath:)` reads it. A plugin is let in only on the old one —
    /// `PluginRoute` names no `/devices/…` path, so it stays shut to them.
    static func deviceRoutes(_ leaf: String) -> [String] {
        ["/devices/:udid/\(leaf)", "/simulators/:udid/\(leaf)"]
    }

    /// The per-button image path under both trees. Its udid is the
    /// second segment, not the second-to-last, so `udidParam` doesn't read it.
    static var chromeButtonRoutes: [String] {
        ["/devices/:udid/chrome-button/:file", "/simulators/:udid/chrome-button/:file"]
    }

    /// The tree a request came in on — `devices` or `simulators` — so the
    /// URLs it answers with stay on it.
    static func tree(of request: Request) -> String {
        request.uri.path.split(separator: "/").first.map(String.init) == "devices" ? "devices" : "simulators"
    }

    /// Every screenshot path, each format under both trees.
    static var screenshotRoutes: [String] {
        CaptureImageFormat.allCases.flatMap { deviceRoutes("screenshot.\($0.pathExtension)") }
    }

    /// The `/devices/:udid/…` route that replaces an old
    /// `/simulators/:udid/<leaf>` one, or nil for a path that isn't one —
    /// the list page, `/simulators.json`, a device's page, anything on the
    /// devices tree.
    static func successor(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "simulators" else { return nil }
        return "/devices/" + parts.dropFirst().joined(separator: "/")
    }

    /// Marks a response from the old `/simulators/:udid/…` spelling
    /// deprecated, naming the `/devices` route that replaces it. The route
    /// still answers; a script calling it learns where to move.
    struct SimulatorTreeDeprecation<Context: RequestContext>: RouterMiddleware {
        func handle(
            _ request: Request,
            context: Context,
            next: (Request, Context) async throws -> Response
        ) async throws -> Response {
            var response = try await next(request, context)
            if let successor = Server.successor(of: request.uri.path) {
                response.headers[HTTPField.Name("Deprecation")!] = "true"
                response.headers[HTTPField.Name("Link")!] = "<\(successor)>; rel=\"successor-version\""
            }
            return response
        }
    }

    /// The role a route acts with on the device a path names — or that
    /// no device has that id, or why the one that does refuses.
    enum RouteRole<Role> {
        case role(Role)
        case unknownDevice
        case refused(DeviceError)
    }

    static func role<Role>(_ ability: Ability<Role>, of udid: String, in devices: any Devices) -> RouteRole<Role> {
        guard !udid.isEmpty else { return .unknownDevice }
        do {
            return .role(try devices.require(ability, of: DeviceID(udid)))
        } catch DeviceError.unknown {
            return .unknownDevice
        } catch let refusal as DeviceError {
            return .refused(refusal)
        } catch {
            return .unknownDevice
        }
    }

    /// A refusal as the page reads it: what the device can't do (422), or
    /// that it isn't running or two sources claim it (409).
    static func refusal(_ refusal: DeviceError) -> Response {
        let status: HTTPResponse.Status
        switch refusal {
        case .unknown: status = .notFound
        case .unable: status = .unprocessableContent
        case .notReady, .claimedTwice: status = .conflict
        }
        return pluginError(refusal.description, status: status)
    }

    /// `GET …/device.json` — one device as the page reads it: who it is,
    /// its kind, its state and what it can do, so the page shows only the
    /// controls the device has abilities for.
    func registerDeviceListingRoute(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?
    ) {
        let devices = allDevices
        for path in Self.deviceRoutes("device.json") {
            router.get(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                guard let json = Self.deviceListingJSON(udid: Self.udidParam(r), devices: devices) else {
                    return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
                }
                return Self.jsonResponse(json)
            }
        }
    }

    /// The device's listing, or nil when no device has that id.
    static func deviceListingJSON(udid: String, devices: any Devices) -> String? {
        guard !udid.isEmpty, let device = (try? devices.find(id: DeviceID(udid))) ?? nil,
              let data = try? JSONSerialization.data(withJSONObject: device.listing, options: [.sortedKeys])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static let okJSON = Response(
        status: .ok,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(string: "{\"ok\":true}"))
    )
}
