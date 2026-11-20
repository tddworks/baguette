import Foundation
import Mockable
import Testing
@testable import WebRTCKit

private func hex(_ string: String) -> Data {
    Data(stride(from: 0, to: string.count, by: 2).map {
        let start = string.index(string.startIndex, offsetBy: $0)
        return UInt8(string[start..<string.index(start, offsetBy: 2)], radix: 16)!
    })
}

private let offer = try! SessionDescription(offer: [
    "v=0", "m=video 9 UDP/TLS/RTP/SAVPF 112", "a=mid:0",
    "a=ice-ufrag:h6vY", "a=ice-pwd:browserpasswordbrowserpass",
    "a=fingerprint:sha-256 6B:8B", "a=setup:actpass",
    "a=rtpmap:112 H264/90000",
    "a=fmtp:112 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=64001f",
].joined(separator: "\r\n"))

/// RFC 5769's sample check is addressed to "evtj" and signed with this password.
private let ours = ICECredentials(ufrag: "evtj", password: "VOkJxbRl1RmTxUk/WvJxBt")
private let check = hex(
    "000100582112a442b7e7a701bc34d686fa87dfae802200105354554e207465737420636c69656e74"
    + "002400046e0001ff80290008932ff9b151263b36000600096576746a3a68367659202020"
    + "000800149aeaa70cbfd8cb56781ef2b5b2d3f249c1b571a280280004e57a3bcf")
private let browser = DatagramAddress(ip: [192, 0, 2, 1], port: 32853)
private let here = [DatagramAddress(ip: [192, 168, 2, 221], port: 50000)]
private let export: [UInt8] = Array(0..<16) + Array(0xA0..<0xB0) + Array(0x10..<0x1E) + Array(0xB0..<0xBE)
private let dtlsHello = Data([0x16, 0xFE, 0xFD, 0, 0])
private let sps = Data([0x67, 0x64, 0x00, 0x1F, 0xAC]), pps = Data([0x68, 0xEE, 0x3C, 0x80])
private func picture(_ nal: Data) -> Data { Data([0, 0, 0, UInt8(nal.count)]) + nal }

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A sender wired to mocks — its socket, its handshake, its congestion control
/// and its owner — with what it sent. No stream, no device.
private struct Rig {
    let datagrams = MockDatagrams()
    let handshake = MockHandshake()
    let congestion = MockCongestionControl()
    let events = MockSenderEvents()
    let sent = Box<[(Data, DatagramAddress)]>([])
    let received = Box<(@Sendable (Data, DatagramAddress) -> Void)?>(nil)
    let sender: WebRTCSender

    init(progress: HandshakeProgress = .complete(replies: [], srtpExport: export), target: Int? = nil) {
        given(datagrams).addresses.willReturn(here)
        given(datagrams).send(.any, to: .any).willProduce { [sent] data, to in sent.value.append((data, to)) }
        given(datagrams).onReceive(.any).willProduce { [received] handler in received.value = handler }
        given(datagrams).close().willReturn()
        given(handshake).fingerprint.willReturn("sha-256 AA:BB")
        given(handshake).receive(.any).willReturn(progress)
        given(congestion).answerLines().willReturn([])
        given(congestion).extensions(at: .any).willReturn([])
        given(congestion).sent(size: .any, at: .any).willReturn()
        given(congestion).heard(.any, at: .any).willReturn(nil)
        given(congestion).target.willReturn(target)
        given(events).keyframeNeeded().willReturn()
        given(events).estimated(bitrate: .any, at: .any).willReturn()
        given(events).hungUp().willReturn()
        given(events).diagnostic(.any).willReturn()
        sender = WebRTCSender(
            offer: offer, ice: ours, ssrc: 0xCAFE_BABE, firstSequence: 1000,
            datagrams: datagrams, handshake: handshake, congestion: congestion,
            encoderBitrate: { 8_000_000 }, events: events, schedule: { _, _ in })
    }

    func deliver(_ data: Data, from address: DatagramAddress = browser) { received.value?(data, address) }
    func goLive() { deliver(check); deliver(dtlsHello) }
    var packets: [RTPPacket] { sent.value.compactMap { RTPPacket($0.0) }.filter { !RTPPacket.isRTCP($0.data) } }
}

@Suite("WebRTCSender")
struct WebRTCSenderTests {
    @Test func `should ask its owner for a keyframe once its handshake completes`() {
        let rig = Rig()

        rig.goLive()

        #expect(rig.sender.state == .live)
        verify(rig.events).keyframeNeeded().called(1)
    }

    @Test func `should send a frame as SRTP packets once live, and nothing before`() {
        let rig = Rig()
        let frame = EncodedFrame(avcc: picture(Data([0x65, 1, 2, 3])), isKeyframe: true, parameterSets: [sps, pps])

        rig.sender.send(frame)
        #expect(rig.packets.isEmpty)
        rig.goLive()
        rig.sender.send(frame)

        #expect(rig.packets.map(\.sequence) == [1000, 1001])
        #expect(rig.packets.map(\.marker) == [false, true])
    }

    @Test func `should tell its owner what the link can take after the browser's feedback`() {
        let rig = Rig(target: 4_000_000)
        rig.goLive()

        rig.sender.act(on: [.bandwidthEstimate(bitsPerSecond: 4_000_000)])

        verify(rig.events).estimated(bitrate: .value(4_000_000), at: .any).called(1)
    }

    @Test func `should tell its owner it hung up, once, when its handshake fails`() {
        let rig = Rig(progress: .failed)

        rig.goLive()
        rig.sender.hangUp()

        #expect(rig.sender.state == .hungUp)
        verify(rig.events).hungUp().called(1)
        verify(rig.datagrams).close().called(1)
    }
}
