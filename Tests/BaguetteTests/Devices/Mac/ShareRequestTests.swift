import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// What a viewer asks for when sharing this Mac to their device: who they
/// are, their screen, how much room, and how the display is used.
@Suite("ShareRequest")
struct ShareRequestTests {
    @Test func `should read a viewer's screen, room and use`() throws {
        let request = try ShareRequest.parse(#"{"viewer":"iPhone","width":402,"height":874,"scale":3,"room":"moreSpace","use":"main"}"#)
        #expect(request.viewer == "iPhone")
        #expect(request.shape == SharedScreenShape(viewer: ViewerScreen(points: Size(width: 402, height: 874), pixelsPerPoint: 3),
                                                   room: .moreSpace))
        #expect(request.use == .main)
    }

    @Test func `should take standard room, an extra display and a plain name when the viewer names none`() throws {
        let request = try ShareRequest.parse(#"{"width":402,"height":874}"#)
        #expect(request.viewer == "viewer")
        #expect(request.shape.points == Size(width: 603, height: 1311))
        #expect(request.use == .extra)
    }

    @Test func `should refuse a request without a screen, or naming a room or use there isn't`() {
        #expect(throws: ShareRequest.Invalid.self) { try ShareRequest.parse(#"{"viewer":"iPhone"}"#) }
        #expect(throws: ShareRequest.Invalid.self) { try ShareRequest.parse(#"{"width":0,"height":874}"#) }
        #expect(throws: ShareRequest.Invalid.self) { try ShareRequest.parse(#"{"width":402,"height":874,"room":"huge"}"#) }
        #expect(throws: ShareRequest.Invalid.self) { try ShareRequest.parse(#"{"width":402,"height":874,"use":"side"}"#) }
        #expect(throws: ShareRequest.Invalid.self) { try ShareRequest.parse("not json") }
    }

    @Test func `should refuse a screen no device has, whose shape would overflow`() {
        #expect(throws: ShareRequest.Invalid.self) { try ShareRequest.parse(#"{"width":1e308,"height":874,"room":"moreSpace"}"#) }
        #expect(throws: ShareRequest.Invalid.self) { try ShareRequest.parse(#"{"width":402,"height":20001}"#) }
        #expect(throws: ShareRequest.Invalid.self) { try ShareRequest.parse(#"{"width":402,"height":874,"scale":1e308}"#) }
        #expect(throws: ShareRequest.Invalid.self) { try ShareRequest.parse(#"{"width":402,"height":874,"scale":0}"#) }
    }
}
