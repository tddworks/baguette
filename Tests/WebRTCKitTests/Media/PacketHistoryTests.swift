import Foundation
import Testing
@testable import WebRTCKit

/// A 1,200-byte packet as it left, its sequence number in its first byte.
private func wire(_ sequence: UInt16) -> Data { Data([UInt8(sequence & 0xFF)]) + Data(repeating: 0, count: 1_199) }

@Suite("PacketHistory")
struct PacketHistoryTests {
    @Test func `should resend the packets the browser lost, as they were sent`() {
        var history = PacketHistory<Data>()
        for sequence in UInt16(1000)...1002 { history.sent(wire(sequence), sequence: sequence, at: 0) }

        let resent = history.resend([1000, 1002], at: 50_000, target: 8_000_000)

        #expect(resent == [wire(1000), wire(1002)])
    }

    @Test func `should not resend a packet it never sent or no longer holds`() {
        var history = PacketHistory<Data>()
        history.sent(wire(1000), sequence: 1000, at: 0)

        #expect(history.resend([999, 1001], at: 50_000, target: 8_000_000).isEmpty)
    }

    @Test func `should not resend a packet too old to arrive in time`() {
        var history = PacketHistory<Data>()
        history.sent(wire(1000), sequence: 1000, at: 0)
        history.sent(wire(1001), sequence: 1001, at: 900_000)

        let resent = history.resend([1000, 1001], at: 1_100_000, target: 8_000_000)

        #expect(resent == [wire(1001)])
    }

    @Test func `should not resend a packet it resent a moment ago`() {
        var history = PacketHistory<Data>()
        history.sent(wire(1000), sequence: 1000, at: 0)
        _ = history.resend([1000], at: 50_000, target: 8_000_000)

        #expect(history.resend([1000], at: 100_000, target: 8_000_000).isEmpty)
        #expect(history.resend([1000], at: 200_000, target: 8_000_000) == [wire(1000)])
    }

    @Test func `should keep resends under half the target bitrate`() {
        var history = PacketHistory<Data>()
        for sequence in UInt16(0)..<200 { history.sent(wire(sequence), sequence: sequence, at: 0) }

        // Half of 1 Mbps is 62,500 bytes a second, and a second's worth at most:
        // 52 packets of 1,200 at once, then one more every ~19 ms.
        let resent = history.resend(Array(0..<200), at: 10_000, target: 1_000_000)

        #expect(resent.count == 52)
        #expect(history.resend([199], at: 10_001, target: 1_000_000).isEmpty)
        #expect(history.resend([199], at: 40_000, target: 1_000_000) == [wire(199)])
    }

    @Test func `should forget the oldest packets beyond what it holds`() {
        var history = PacketHistory<Data>(capacity: 3)
        for sequence in UInt16(0)..<4 { history.sent(wire(sequence), sequence: sequence, at: 0) }

        #expect(history.resend([0, 1, 2, 3], at: 10_000, target: 8_000_000) == [wire(1), wire(2), wire(3)])
    }
}
