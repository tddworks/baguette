import Foundation
import Testing
@testable import Baguette

@Suite("ReceiverFeedback")
struct ReceiverFeedbackTests {
    private let reporter: UInt32 = 0xD6AF_5E2E
    private let source: UInt32 = 0xE95D_3647

    private func packet(sequence: UInt16, marker: Bool = false, timestamp: UInt32 = 1600) -> RTPPacket {
        var bytes: [UInt8] = [0x80, (marker ? 0x80 : 0) | 123, UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        bytes += withUnsafeBytes(of: timestamp.bigEndian, Array.init)
        bytes += withUnsafeBytes(of: source.bigEndian, Array.init)
        bytes += [0x41, 0x9A]
        return RTPPacket(Data(bytes))!
    }

    private func report(highest: UInt32) -> Data {
        RTCPReceiverReport(reporter: reporter, source: source, highestSequence: highest).bytes
    }

    @Test func `should report to the phone once a second, so it keeps streaming`() {
        var feedback = ReceiverFeedback(reporter: reporter, source: source)

        let first = feedback.due(at: 0, wantingKeyframe: false)
        let halfway = feedback.due(at: 0.5, wantingKeyframe: false)
        let second = feedback.due(at: 1, wantingKeyframe: false)

        #expect(first == [report(highest: 0)])
        #expect(halfway.isEmpty)
        #expect(second == [report(highest: 0)])
    }

    @Test func `should acknowledge a picture as its last packet arrives`() {
        var feedback = ReceiverFeedback(reporter: reporter, source: source)

        let middle = feedback.heard(packet(sequence: 7))
        let last = feedback.heard(packet(sequence: 8, marker: true, timestamp: 2400))

        #expect(middle.isEmpty)
        #expect(last == [RTCPReceiverReport.pictureReceived(reporter: reporter, timestamp: 2400)])
    }

    @Test func `should tell the phone every 50 ms how many pictures and packets arrived, once they flow`() {
        var feedback = ReceiverFeedback(reporter: reporter, source: source)
        _ = feedback.due(at: 0, wantingKeyframe: false)
        let before = feedback.due(at: 0.05, wantingKeyframe: false)

        _ = feedback.heard(packet(sequence: 10))
        _ = feedback.heard(packet(sequence: 11, marker: true))
        let after = feedback.due(at: 0.1, wantingKeyframe: false)
        let soon = feedback.due(at: 0.12, wantingKeyframe: false)

        #expect(before.isEmpty)
        #expect(after == [RTCPReceiverReport.receiverControl(reporter: reporter, clock: 100, pictures: 1, packets: 1)])
        #expect(soon.isEmpty)
    }

    @Test func `should report the highest sequence it has heard`() {
        var feedback = ReceiverFeedback(reporter: reporter, source: source)
        _ = feedback.heard(packet(sequence: 0x6D4E))

        #expect(feedback.due(at: 0, wantingKeyframe: false).first == report(highest: 0x6D4E))
    }

    @Test func `should ask for a keyframe every 300 ms while one is wanted, and stop once not`() {
        var feedback = ReceiverFeedback(reporter: reporter, source: source)
        let pli = RTCPReceiverReport.pictureLossIndication(reporter: reporter, source: source)

        let asked = feedback.due(at: 0, wantingKeyframe: true)
        let tooSoon = feedback.due(at: 0.1, wantingKeyframe: true)
        let again = feedback.due(at: 0.3, wantingKeyframe: true)
        let satisfied = feedback.due(at: 0.6, wantingKeyframe: false)

        #expect(asked.contains(pli))
        #expect(!tooSoon.contains(pli))
        #expect(again.contains(pli))
        #expect(!satisfied.contains(pli))
    }
}
