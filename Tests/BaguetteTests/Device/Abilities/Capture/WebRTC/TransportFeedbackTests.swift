import Foundation
import Testing
@testable import BaguetteDevice

/// A transport-cc FCI (draft-holmer-rmcat-transport-wide-cc-extensions-01 §3.1):
/// base sequence, status count, 24-bit reference time (×64 ms), feedback count,
/// then the chunks and the receive deltas.
private func fci(base: UInt16, count: UInt16, reference: Int32, feedbackCount: UInt8, _ rest: [UInt8]) -> [UInt8] {
    let ref = UInt32(bitPattern: reference) & 0x00FF_FFFF
    return [UInt8(base >> 8), UInt8(base & 0xFF), UInt8(count >> 8), UInt8(count & 0xFF),
            UInt8(ref >> 16), UInt8(ref >> 8 & 0xFF), UInt8(ref & 0xFF), feedbackCount] + rest
}

@Suite("TransportFeedback")
struct TransportFeedbackTests {
    @Test func `should read when each packet of a run arrived, from the reference time and small deltas`() throws {
        // One run-length chunk: 3 × "received, small delta" (0b0_01_0000000000011).
        let feedback = try #require(TransportFeedback(fci: fci(
            base: 100, count: 3, reference: 1, feedbackCount: 5, [0x20, 0x03, 4, 8, 1])))

        #expect(feedback.feedbackCount == 5)
        #expect(feedback.arrivals == [
            .init(sequence: 100, microseconds: 65_000),   // 64 ms + 4 × 250 µs
            .init(sequence: 101, microseconds: 67_000),
            .init(sequence: 102, microseconds: 67_250),
        ])
    }

    @Test func `should read a two-bit status vector, with a lost packet and a large negative delta`() throws {
        // 0b1_1_01_00_10_01_00_00_00: small, not received, large, small (the rest past the count).
        let feedback = try #require(TransportFeedback(fci: fci(
            base: 7, count: 4, reference: 0, feedbackCount: 0, [0xD2, 0x40, 0x04, 0xFF, 0xF8, 0x08])))

        #expect(feedback.arrivals == [
            .init(sequence: 7, microseconds: 1_000),
            .init(sequence: 8, microseconds: nil),
            .init(sequence: 9, microseconds: -1_000),   // −8 × 250 µs
            .init(sequence: 10, microseconds: 1_000),
        ])
    }

    @Test func `should read a one-bit status vector`() throws {
        // 0b1_0_101_00000000000: received, not received, received.
        let feedback = try #require(TransportFeedback(fci: fci(
            base: 1, count: 3, reference: 0, feedbackCount: 0, [0xA8, 0x00, 0x02, 0x02])))

        #expect(feedback.arrivals.map(\.microseconds) == [500, nil, 1_000])
    }

    @Test func `should number packets across the sequence wraparound`() throws {
        let feedback = try #require(TransportFeedback(fci: fci(
            base: 65_535, count: 2, reference: 0, feedbackCount: 0, [0x20, 0x02, 1, 1])))

        #expect(feedback.arrivals.map(\.sequence) == [65_535, 0])
    }

    @Test func `should read a reference time from before the clock's zero`() throws {
        let feedback = try #require(TransportFeedback(fci: fci(
            base: 0, count: 1, reference: -1, feedbackCount: 0, [0x20, 0x01, 0])))

        #expect(feedback.arrivals.first?.microseconds == -64_000)
    }

    @Test func `should read nothing from a chunk that uses the reserved status symbol`() {
        // A run of "3" (0b0_11_…), and a two-bit vector starting with 3 (0b1_1_11_…).
        #expect(TransportFeedback(fci: fci(base: 0, count: 1, reference: 0, feedbackCount: 0, [0x60, 0x01, 0])) == nil)
        #expect(TransportFeedback(fci: fci(base: 0, count: 1, reference: 0, feedbackCount: 0, [0xF0, 0x00, 0])) == nil)
    }

    @Test func `should read nothing from feedback cut short`() {
        #expect(TransportFeedback(fci: [0, 1, 0, 3]) == nil)
        // Three packets reported received, but only one delta present.
        #expect(TransportFeedback(fci: fci(base: 0, count: 3, reference: 0, feedbackCount: 0, [0x20, 0x03, 4])) == nil)
        // A status count with no chunk to say what happened.
        #expect(TransportFeedback(fci: fci(base: 0, count: 2, reference: 0, feedbackCount: 0, [])) == nil)
    }
}

extension RTCPFeedbackTests {
    @Test func `should read transport-cc feedback among the browser's reports`() throws {
        let body: [UInt8] = [0, 0, 0, 1, 0xCA, 0xFE, 0xBA, 0xBE]
            + fci(base: 100, count: 1, reference: 0, feedbackCount: 0, [0x20, 0x01, 4, 0])   // padded to a word
        let packet = [0x80 | 15, 205, 0, UInt8(body.count / 4)] + body

        let read = RTCPFeedback.parse(Data(packet))

        #expect(read == [.transportFeedback(TransportFeedback(fci: Array(body[8...]))!)])
    }
}
