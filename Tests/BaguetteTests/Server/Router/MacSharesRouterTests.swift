import Foundation
import HTTPTypes
import HummingbirdTesting
import Mockable
import NIOCore
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `/mac/shares`: sharing this Mac to a viewer's device through a display of
/// its shape — started, reshaped and ended through the real router.
@Suite("MacSharesRouter")
struct MacSharesRouterTests {
    static func shares(makes: Bool = true) -> (ScreenShares, MockVirtualDisplay) {
        let made = MockVirtualDisplay()
        given(made).uuid.willReturn("VIRTUAL-UUID")
        given(made).id.willReturn(7)
        given(made).remove().willReturn()
        let displays = MockVirtualDisplays()
        given(displays).create(named: .any, shape: .any, serial: .any).willReturn(makes ? made : nil)
        let arrangement = MockDisplayArrangement()
        given(arrangement).main.willReturn(1)
        given(arrangement).makeMain(.any).willReturn(true)
        return (ScreenShares(displays: displays, arrangement: arrangement), made)
    }

    static let body = ByteBuffer(string: #"{"viewer":"iPhone","width":402,"height":874,"scale":3}"#)

    @Test func `should share the Mac to a viewer through a display of its shape, answering the display's id`() async throws {
        let (shares, _) = Self.shares()
        try await InProcessServer(screenShares: shares).test { client in
            let response = try await client.execute(uri: "/mac/shares", method: .post, body: Self.body)
            #expect(response.status == .created)
            #expect(response.json["id"] as? String == "VIRTUAL-UUID")
            #expect(shares.isSharing("VIRTUAL-UUID"))
        }
    }

    @Test func `should reshape a share and end it`() async throws {
        let (shares, made) = Self.shares()
        try await InProcessServer(screenShares: shares).test { client in
            _ = try await client.execute(uri: "/mac/shares", method: .post, body: Self.body)
            let turned = ByteBuffer(string: #"{"width":874,"height":402,"scale":3}"#)
            let reshaped = try await client.execute(uri: "/mac/shares/VIRTUAL-UUID", method: .put, body: turned)
            let ended = try await client.execute(uri: "/mac/shares/VIRTUAL-UUID", method: .delete)
            #expect(reshaped.status == .ok)
            #expect(ended.status == .noContent)
            #expect(!shares.isSharing("VIRTUAL-UUID"))
            verify(made).remove().called(2)   // the turned-from display, then the turned one
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

    @Test func `should not share the Mac when serve wasn't asked to`() async throws {
        try await InProcessServer().test { client in
            let response = try await client.execute(uri: "/mac/shares", method: .post, body: Self.body)
            #expect(response.status == .notFound)
        }
    }
}
