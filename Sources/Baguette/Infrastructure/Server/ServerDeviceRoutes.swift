import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// What every per-device route shares as it moves from `Simulators` to
/// `Devices`: its two spellings, how it finds the role it acts with, and
/// how a refusal answers.
extension Server {

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

    static let okJSON = Response(
        status: .ok,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(string: "{\"ok\":true}"))
    )
}
