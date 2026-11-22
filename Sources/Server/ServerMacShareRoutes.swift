import BaguetteDevice
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// Sharing this Mac to a viewer's device through a display of its shape
/// (`serve --share-mac`): started, reshaped as the viewer turns, ended as it
/// leaves. The display is then a device like any Mac display, at its id.
/// See docs/features/mac-screen/README.md#share-to-your-device.
extension Server {
    func registerMacShareRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?
    ) {
        guard let shares = screenShares else { return }

        // The page a viewer opens on its device to share this Mac to it.
        router.get("/mac/share") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            return Self.staticAsset("mac-share.html")
        }

        router.post("/mac/shares") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let request: ShareRequest
            do { request = try ShareRequest.parse(await Self.bodyText(r)) } catch let invalid as ShareRequest.Invalid {
                return Self.twinJSONResponse(["ok": false, "error": invalid.reason], status: .badRequest)
            }
            let shape = "\(Int(request.shape.points.width))×\(Int(request.shape.points.height)) pt"
            guard let id = shares.start(viewer: request.viewer, shape: request.shape, use: request.use) else {
                log("[mac] share for \(request.viewer) at \(shape) refused: this Mac didn't make the display")
                return Self.twinJSONResponse(["ok": false, "error": "this Mac didn't make the display"],
                                             status: .serviceUnavailable)
            }
            log("[mac] share \(id) started for \(request.viewer): \(shape), \(request.use.rawValue) display")
            return Self.twinJSONResponse(["ok": true, "id": id], status: .created)
        }

        router.put("/mac/shares/:id") { r, context in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let id = context.parameters.get("id") ?? ""
            let request: ShareRequest
            do { request = try ShareRequest.parse(await Self.bodyText(r)) } catch let invalid as ShareRequest.Invalid {
                return Self.twinJSONResponse(["ok": false, "error": invalid.reason], status: .badRequest)
            }
            guard shares.isSharing(id) else {
                log("[mac] reshape for unknown share \(id)")
                return Self.twinJSONResponse(["ok": false, "error": "no share \(id)"], status: .notFound)
            }
            let shape = "\(Int(request.shape.points.width))×\(Int(request.shape.points.height)) pt"
            guard shares.reshape(id, to: request.shape) else {
                log("[mac] share \(id) didn't take \(shape); it ended")
                return Self.twinJSONResponse(["ok": false, "error": "the display didn't take the shape"],
                                             status: .internalServerError)
            }
            log("[mac] share \(id) reshaped to \(shape)")
            return Self.okJSON
        }

        router.delete("/mac/shares/:id") { r, context in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let id = context.parameters.get("id") ?? ""
            log("[mac] share \(id) ended")
            shares.end(id)
            return Response(status: .noContent)
        }
    }

    private static func bodyText(_ r: Request) async -> String {
        (try? await r.body.collect(upTo: 16 * 1024)).map { String(buffer: $0) } ?? ""
    }
}
