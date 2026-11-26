import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// The Mac's pointer shape for a page drawing a Mac display's pointer
/// (`serve --share-mac`): a socket saying each change, and each shape's image
/// by its id. See docs/features/mac-screen/README.md#input.
extension Server {
    func registerMacPointerRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?,
        trustedWebSocketUpgrade: @escaping @Sendable (Request, BasicWebSocketRequestContext) async throws -> RouterShouldUpgrade
    ) {
        guard let shapes = pointerShapes else { return }

        // Each shape as it changes, the current one first, until the page goes.
        router.ws("/mac/pointer", shouldUpgrade: trustedWebSocketUpgrade) { inbound, outbound, _ in
            let (said, saying) = AsyncStream.makeStream(of: String.self)
            let watch = shapes.watch { saying.yield($0.json) }
            let writer = Task {
                for await json in said {
                    do { try await outbound.write(.text(json)) } catch { break }
                }
            }
            do { for try await _ in inbound {} } catch {}   // the page says nothing; this ends when it goes
            watch.end()
            saying.finish()
            await writer.value
        }

        // A shape's image: an id always names the same image, so it keeps.
        router.get("/mac/pointer/:image") { r, context in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let name = context.parameters.get("image") ?? ""
            guard name.hasSuffix(".png"), let png = shapes.image(id: String(name.dropLast(4))) else {
                return Response(status: .notFound)
            }
            return Response(
                status: .ok,
                headers: [.contentType: "image/png", .cacheControl: "public, max-age=31536000, immutable"],
                body: .init(byteBuffer: ByteBuffer(bytes: png)))
        }
    }
}
