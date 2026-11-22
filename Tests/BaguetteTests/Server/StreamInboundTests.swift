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
    /// The Mac taking gestures, held by the test: each waits for `open`, then counts as done.
    final class Mac: @unchecked Sendable {
        let open = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _done: [String] = []
        var done: [String] { lock.withLock { _done } }
        func take(_ name: String, waiting: Bool) -> Bool {
            if waiting { open.wait() }
            lock.withLock { _done.append(name) }
            return true
        }
    }

    static func dispatcher(_ mac: Mac, holdingMoves: Bool) -> GestureDispatcher {
        let touch = MockTouch()
        given(touch).touch1(phase: .any, at: .any, size: .any, edge: .any).willProduce { _, _, _, _ in
            mac.take("move", waiting: holdingMoves)
        }
        given(touch).tap(at: .any, size: .any, duration: .any, edge: .any).willProduce { _, _, _, _ in
            mac.take("tap", waiting: false)
        }
        var abilities = Abilities(device: "Mac")
        abilities.register(.touch) { touch }
        return GestureDispatcher(input: abilities)
    }

    @Test(.timeLimit(.minutes(1)))
    func `should read on past a pointer move without waiting for the Mac to take it`() async throws {
        let mac = Mac()
        let move = #"{"type":"touch1-move","x":1,"y":2,"width":10,"height":10}"#
        try await Server.handleInbound(line: move, stream: MockStream(), dispatcher: Self.dispatcher(mac, holdingMoves: true),
                                       udid: "INBOUND-MOVE")
        #expect(mac.done.isEmpty)   // read on while the Mac still holds the move
        mac.open.signal()
    }

    @Test func `should finish a click before reading on`() async throws {
        let mac = Mac()
        let tap = #"{"type":"tap","x":1,"y":2,"width":10,"height":10}"#
        try await Server.handleInbound(line: tap, stream: MockStream(), dispatcher: Self.dispatcher(mac, holdingMoves: true),
                                       udid: "INBOUND-TAP")
        #expect(mac.done == ["tap"])
    }
}
