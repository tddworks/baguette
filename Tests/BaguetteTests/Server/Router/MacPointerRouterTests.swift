import Foundation
import HTTPTypes
import HummingbirdTesting
import HummingbirdWSTesting
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// The Mac's pointer shape for a page: a socket that says each change, and
/// each shape's image by its id — so the page draws the pointer it really is.
@Suite("MacPointerRouter")
struct MacPointerRouterTests {
    static let ibeam = PointerShape(id: "3de4a52b", hotspot: Point(x: 12, y: 11), size: Size(width: 23, height: 22),
                                    png: Data([0x89, 0x50, 0x4E, 0x47]))

    /// Pointer shapes whose helper process says `ibeam` the moment it runs.
    static func shapes() -> PointerShapes {
        let process = MockSubprocess()
        given(process).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any)
            .willProduce { _, _, onBytes, _ in onBytes(Data((Self.ibeam.line + "\n").utf8)) }
        given(process).terminate().willReturn()
        return PointerShapes(executable: URL(fileURLWithPath: "/usr/local/bin/baguette"), makeProcess: { process })
    }

    @Test func `should tell a page the Mac's pointer shape as it changes`() async throws {
        let server = InProcessServer(pointerShapes: Self.shapes(), allowedHosts: ["localhost"])
        let messages = try await socketConversation("/mac/pointer", server: server, until: { $0.contains("pointer") })
        #expect(messages == [Self.ibeam.json])
    }

    @Test func `should serve a shape's image by its id, to keep`() async throws {
        let shapes = Self.shapes()
        let watch = shapes.watch { _ in }
        defer { watch.end() }
        try await InProcessServer(pointerShapes: shapes).test { client in
            let image = try await client.execute(uri: "/mac/pointer/3de4a52b.png", method: .get)
            let unknown = try await client.execute(uri: "/mac/pointer/nope.png", method: .get)
            #expect(image.status == .ok)
            #expect(image.headers[.contentType] == "image/png")
            #expect(Data(buffer: image.body) == Self.ibeam.png)
            #expect(image.headers[.cacheControl]?.contains("immutable") == true)
            #expect(unknown.status == .notFound)
        }
    }

    @Test func `should offer no pointer when serve wasn't asked to share the Mac`() async throws {
        try await InProcessServer().test { client in
            let image = try await client.execute(uri: "/mac/pointer/3de4a52b.png", method: .get)
            #expect(image.status == .notFound)
        }
    }
}
