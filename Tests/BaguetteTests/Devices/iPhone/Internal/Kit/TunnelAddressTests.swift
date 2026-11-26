import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice
@testable import WebRTCKit

/// RTP header: V=2, P=0, X, CC; M, PT; sequence; timestamp; SSRC.
private func rtp(
    marker: Bool = false, payloadType: UInt8 = 123, sequence: UInt16 = 1, timestamp: UInt32 = 9000,
    ssrc: UInt32 = 0xE95D_3647, csrcs: [UInt32] = [], extensionWords: [UInt32]? = nil, payload: [UInt8]
) -> Data {
    var bytes: [UInt8] = [0x80 | (extensionWords == nil ? 0 : 0x10) | UInt8(csrcs.count),
                          (marker ? 0x80 : 0) | payloadType]
    bytes += withUnsafeBytes(of: sequence.bigEndian, Array.init)
    bytes += withUnsafeBytes(of: timestamp.bigEndian, Array.init)
    bytes += withUnsafeBytes(of: ssrc.bigEndian, Array.init)
    for csrc in csrcs { bytes += withUnsafeBytes(of: csrc.bigEndian, Array.init) }
    if let words = extensionWords {
        bytes += [0x90, 0x11] + withUnsafeBytes(of: UInt16(words.count).bigEndian, Array.init)
        for word in words { bytes += withUnsafeBytes(of: word.bigEndian, Array.init) }
    }
    return Data(bytes + payload)
}

/// A packet the test means to be valid.
private func parsed(_ data: Data) -> RTPPacket { RTPPacket(data)! }

@Suite("TunnelAddress")
struct TunnelAddressTests {
    @Test func `should pick the Mac's address on the phone's tunnel prefix`() {
        let local = TunnelAddress.local(
            facing: "fdd3:48cf:f69f::1",
            among: ["fe80::1", "fd00:1:2::5", "fdd3:48cf:f69f::2", "fdd3:48cf:f69f::1"])

        #expect(local == "fdd3:48cf:f69f::2")
    }

    @Test func `should find no address when the Mac has none on the phone's prefix`() {
        #expect(TunnelAddress.local(facing: "fdd3:48cf:f69f::1", among: ["fe80::1"]) == nil)
    }
}
