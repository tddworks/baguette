import Foundation
import Testing
@testable import BaguetteDevice

/// A picture as the encoder hands it over: each NAL unit behind a 4-byte length.
private func avcc(_ nalUnits: [Data]) -> Data {
    nalUnits.reduce(into: Data()) { out, nal in
        out.append(contentsOf: withUnsafeBytes(of: UInt32(nal.count).bigEndian, Array.init))
        out.append(nal)
    }
}

/// An IDR slice (type 5) of `size` bytes, its header first.
private func idrSlice(_ size: Int) -> Data {
    Data([0x65] + (1..<size).map { UInt8(truncatingIfNeeded: $0) })
}

@Suite("H264Packetizer")
struct H264PacketizerTests {
    let packetizer = H264Packetizer()

    @Test func `should send a NAL unit that fits in one packet as it is`() {
        let nal = idrSlice(300)

        #expect(packetizer.payloads(picture: avcc([nal])) == [nal])
    }

    @Test func `should send each NAL unit of a picture in its own packet, in order`() {
        let first = Data([0x41, 1, 2]), second = Data([0x41, 3, 4])

        #expect(packetizer.payloads(picture: avcc([first, second])) == [first, second])
    }

    @Test func `should fragment a NAL unit too big for one packet into FU-A packets with start and end bits`() {
        let nal = idrSlice(3000)

        let payloads = packetizer.payloads(picture: avcc([nal]))

        #expect(payloads.count == 3)
        #expect(payloads.allSatisfy { $0.count <= H264Packetizer.maxPayload })
        // FU indicator: the NAL's F and NRI bits, type 28. FU header: S/E bits, the NAL's type.
        #expect(payloads.map { $0[0] } == [0x7C, 0x7C, 0x7C])
        #expect(payloads.map { $0[1] } == [0x85, 0x05, 0x45])
        let rebuilt = Data([nal[0]]) + payloads.reduce(into: Data()) { $0.append($1.dropFirst(2)) }
        #expect(rebuilt == nal)
    }

    @Test func `should bundle SPS and PPS into one STAP-A ahead of a keyframe`() {
        let sps = Data([0x67, 0x64, 0x00, 0x1F]), pps = Data([0x68, 0xEE, 0x3C]), slice = idrSlice(10)

        let payloads = packetizer.payloads(picture: avcc([slice]), parameterSets: [sps, pps])

        #expect(payloads == [
            Data([0x78, 0x00, 0x04]) + sps + Data([0x00, 0x03]) + pps,
            slice,
        ])
    }

    @Test func `should send no packets for an empty picture`() {
        #expect(packetizer.payloads(picture: Data()).isEmpty)
    }

    @Test func `should stop at a length that runs past the end of the picture`() {
        let whole = Data([0x41, 1])
        let truncated = avcc([whole]) + Data([0x00, 0x00, 0x00, 0x09, 0x41])

        #expect(packetizer.payloads(picture: truncated) == [whole])
    }
}
