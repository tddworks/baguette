import Foundation
import HTTPTypes
import HummingbirdTesting
import Mockable
import NIOCore
import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// `/mac/shares`: sharing this Mac to a viewer's device through a display of
/// its shape — started, reshaped and ended through the real router.
@Suite("MacSharesRouter")
struct MacSharesRouterTests {
    /// Shares whose Mac makes `made` first and `turned` when the viewer turns
    /// — one device id, two displays.
    static func shares(makes: Bool = true) -> (VirtualDisplayShares, made: MockVirtualDisplay, turned: MockVirtualDisplay) {
        let (made, turned) = (MockVirtualDisplay(), MockVirtualDisplay())
        for (display, id) in [(made, UInt32(7)), (turned, 8)] {
            given(display).uuid.willReturn("VIRTUAL-UUID")
            given(display).id.willReturn(id)
            given(display).remove().willReturn()
        }
        var next = [made, turned]
        let displays = MockVirtualDisplays()
        given(displays).create(named: .any, shape: .any, serial: .any).willProduce { _, _, _ in
            makes && !next.isEmpty ? next.removeFirst() : nil
        }
        let arrangement = MockDisplayArrangement()
        given(arrangement).main.willReturn(1)
        given(arrangement).makeMain(.any, freeingDock: .any).willReturn(true)
        return (VirtualDisplayShares(displays: displays, arrangement: arrangement), made, turned)
    }

    static let body = ByteBuffer(string: #"{"viewer":"iPhone","width":402,"height":874,"scale":3}"#)

    @Test func `should share the Mac to a viewer through a display of its shape, answering the display's id`() async throws {
        let (shares, _, _) = Self.shares()
        try await InProcessServer(screenShares: shares).test { client in
            let response = try await client.execute(uri: "/mac/shares", method: .post, body: Self.body)
            #expect(response.status == .created)
            #expect(response.json["id"] as? String == "VIRTUAL-UUID")
            #expect(shares.isSharing("VIRTUAL-UUID"))
        }
    }

    @Test func `should reshape a share and end it`() async throws {
        let (shares, made, remade) = Self.shares()
        try await InProcessServer(screenShares: shares).test { client in
            _ = try await client.execute(uri: "/mac/shares", method: .post, body: Self.body)
            let turned = ByteBuffer(string: #"{"width":874,"height":402,"scale":3}"#)
            let reshaped = try await client.execute(uri: "/mac/shares/VIRTUAL-UUID", method: .put, body: turned)
            let ended = try await client.execute(uri: "/mac/shares/VIRTUAL-UUID", method: .delete)
            #expect(reshaped.status == .ok)
            #expect(ended.status == .noContent)
            #expect(!shares.isSharing("VIRTUAL-UUID"))
            verify(made).remove().called(1)     // the turned-from display, as the viewer turned
            verify(remade).remove().called(1)   // the turned one, as the viewer left
        }
    }

    @Test func `should refuse to reshape a share to a screen that isn't one`() async throws {
        let shares = MockScreenShares()
        try await InProcessServer(screenShares: shares).test { client in
            let bad = try await client.execute(uri: "/mac/shares/SHARED-UUID", method: .put, body: ByteBuffer(string: "{}"))
            #expect(bad.status == .badRequest)
        }
    }

    @Test func `should say the share ended when its display won't take the new shape`() async throws {
        let shares = MockScreenShares()
        given(shares).isSharing(.any).willReturn(true)
        given(shares).reshape(.any, to: .any).willReturn(false)
        try await InProcessServer(screenShares: shares).test { client in
            let failed = try await client.execute(uri: "/mac/shares/SHARED-UUID", method: .put, body: Self.body)
            #expect(failed.status == .internalServerError)
            #expect(failed.json["error"] as? String == "the display didn't take the shape")
        }
    }

    @Test func `should end a share through any screen shares when its viewer leaves`() async throws {
        let shares = MockScreenShares()
        given(shares).end(.any).willReturn()
        try await InProcessServer(screenShares: shares).test { client in
            let ended = try await client.execute(uri: "/mac/shares/SHARED-UUID", method: .delete)
            #expect(ended.status == .noContent)
            verify(shares).end(.value("SHARED-UUID")).called(1)
        }
    }

    @Test func `should refuse a share the Mac can't make, a bad request, and an unknown share`() async throws {
        try await InProcessServer(screenShares: Self.shares(makes: false).0).test { client in
            let unmade = try await client.execute(uri: "/mac/shares", method: .post, body: Self.body)
            let bad = try await client.execute(uri: "/mac/shares", method: .post, body: ByteBuffer(string: "{}"))
            let unknown = try await client.execute(uri: "/mac/shares/nope", method: .put, body: Self.body)
            #expect(unmade.status == .serviceUnavailable)
            #expect(bad.status == .badRequest)
            #expect(unknown.status == .notFound)
        }
    }

    @Test func `should offer the page that shares this Mac to the device it's opened on`() async throws {
        try await InProcessServer(screenShares: Self.shares().0).test { client in
            let page = try await client.execute(uri: "/mac/share", method: .get)
            // The web root may be out of a test binary's reach: the route
            // answers what serving the page answers, as the other pages' do.
            let served = Server.staticAsset("mac-share.html")
            #expect(page.status == served.status)
            #expect(page.headers[.contentType] == served.headers[.contentType])
        }
    }

    @Test func `should not share the Mac when serve wasn't asked to`() async throws {
        try await InProcessServer().test { client in
            let response = try await client.execute(uri: "/mac/shares", method: .post, body: Self.body)
            let page = try await client.execute(uri: "/mac/share", method: .get)
            #expect(response.status == .notFound)
            #expect(page.status == .notFound)
            #expect(!String(buffer: page.body).contains("mac-share.html"))
        }
    }
}
