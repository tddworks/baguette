import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// A stream socket's messages: a pointer move is handed to the device's lane
/// and the next message read at once — so a newer move can replace it — while
/// anything else is done before the next is read.
@Suite("Stream inbound")
struct StreamInboundTests {
    static func dispatcher(pausing seconds: TimeInterval) -> GestureDispatcher {
        let touch = MockTouch()
        given(touch).touch1(phase: .any, at: .any, size: .any, edge: .any).willProduce { _, _, _, _ in
            Thread.sleep(forTimeInterval: seconds); return true
        }
        given(touch).tap(at: .any, size: .any, duration: .any, edge: .any).willProduce { _, _, _, _ in
            Thread.sleep(forTimeInterval: seconds); return true
        }
        var abilities = Abilities(device: "Mac")
        abilities.register(.touch) { touch }
        return GestureDispatcher(input: abilities)
    }

    static func took(_ body: () async throws -> Void) async rethrows -> TimeInterval {
        let start = Date()
        try await body()
        return Date().timeIntervalSince(start)
    }

    @Test func `should read on past a pointer move without waiting for the Mac to take it`() async throws {
        let dispatcher = Self.dispatcher(pausing: 0.3)
        let move = #"{"type":"touch1-move","x":1,"y":2,"width":10,"height":10}"#
        let seconds = try await Self.took {
            try await Server.handleInbound(line: move, stream: MockStream(), dispatcher: dispatcher, udid: "INBOUND-MOVE")
        }
        #expect(seconds < 0.1)
    }

    @Test func `should finish a click before reading on`() async throws {
        let dispatcher = Self.dispatcher(pausing: 0.2)
        let tap = #"{"type":"tap","x":1,"y":2,"width":10,"height":10}"#
        let seconds = try await Self.took {
            try await Server.handleInbound(line: tap, stream: MockStream(), dispatcher: dispatcher, udid: "INBOUND-TAP")
        }
        #expect(seconds >= 0.2)
    }
}
