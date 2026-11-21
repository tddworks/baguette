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

/// The same offer, pairing a resend format (RTX, RFC 4588) with our H.264.
private let offerWithRTX = try! SessionDescription(offer: [
    "v=0", "m=video 9 UDP/TLS/RTP/SAVPF 112 113", "a=mid:0",
    "a=ice-ufrag:h6vY", "a=ice-pwd:browserpasswordbrowserpass",
    "a=fingerprint:sha-256 6B:8B", "a=setup:actpass",
    "a=rtpmap:112 H264/90000",
    "a=fmtp:112 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=64001f",
    "a=rtpmap:113 rtx/90000", "a=fmtp:113 apt=112",
].joined(separator: "\r\n"))

/// The offer as a browser posts it after gathering: one address of its own.
private let browserCandidate = DatagramAddress(ip: [192, 168, 1, 20], port: 54400)
private let offerWithCandidate = try! SessionDescription(offer: [
    "v=0", "m=video 9 UDP/TLS/RTP/SAVPF 112", "a=mid:0",
    "a=ice-ufrag:h6vY", "a=ice-pwd:browserpasswordbrowserpass",
    "a=fingerprint:sha-256 6B:8B", "a=setup:actpass",
    "a=candidate:1 1 udp 2122260223 192.168.1.20 54400 typ host",
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
    /// Work the sender asked to run later, run by `pass()`.
    let scheduled = Box<[@Sendable () -> Void]>([])
    let sender: WebRTCSender

    init(
        progress: HandshakeProgress = .complete(replies: [], srtpExport: export), target: Int? = nil,
        offer: SessionDescription = offer, reflexive: DatagramAddress? = nil, relay: DatagramAddress? = nil
    ) {
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
            rtxSSRC: 0xFEED_F00D, firstRetransmissionSequence: 500,
            datagrams: datagrams, handshake: handshake, congestion: congestion,
            encoderBitrate: { 8_000_000 }, events: events,
            schedule: { [scheduled] _, work in scheduled.value.append(work) }, reflexive: reflexive, relay: relay)
    }

    func deliver(_ data: Data, from address: DatagramAddress = browser) { received.value?(data, address) }
    /// Runs what was due, once.
    func pass() {
        let due = scheduled.value
        scheduled.value = []
        due.forEach { $0() }
    }
    /// The connectivity checks it sent, and to where.
    var checks: [DatagramAddress] {
        sent.value.filter { STUNMessage($0.0)?.isBindingRequest == true }.map(\.1)
    }
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

    @Test func `should resend a lost packet once for reports that repeat a moment apart`() {
        let rig = Rig()
        rig.goLive()
        rig.sender.send(EncodedFrame(avcc: picture(Data([0x65, 1, 2, 3])), isKeyframe: true, parameterSets: [sps, pps]))
        let before = rig.packets.count

        rig.sender.act(on: [.lost([1000])])
        rig.sender.act(on: [.lost([1000])])

        #expect(rig.packets.count == before + 1)
        #expect(rig.packets.last?.sequence == 1000)
    }

    @Test func `should resend a lost packet on its own stream, stamped anew, when the browser takes resends there`() {
        let rig = Rig(offer: offerWithRTX)
        rig.goLive()
        rig.sender.send(EncodedFrame(avcc: picture(Data([0x65, 1, 2, 3])), isKeyframe: true, parameterSets: [sps, pps]))

        rig.sender.act(on: [.lost([1000])])

        let resend = rig.packets.last
        #expect(resend?.ssrc == 0xFEED_F00D && resend?.payloadType == 113 && resend?.sequence == 500)
        // Two packets and the resend: each stamped and reported sent, so the
        // original's loss reads as a loss and the resend as what it is.
        verify(rig.congestion).extensions(at: .any).called(3)
        verify(rig.congestion).sent(size: .any, at: .any).called(3)
    }

    @Test func `should offer its relayed address when it has one`() {
        let rig = Rig(relay: DatagramAddress(ip: [198, 51, 100, 4], port: 50001))

        #expect(rig.sender.answer.contains("198.51.100.4 50001 typ relay raddr 0.0.0.0 rport 0"))
    }

    @Test func `should offer its public address beside its own when it has one`() {
        let rig = Rig(reflexive: DatagramAddress(ip: [203, 0, 113, 7], port: 61000))

        #expect(rig.sender.answer.contains("203.0.113.7 61000 typ srflx raddr 0.0.0.0 rport 0"))
        #expect(!Rig().sender.answer.contains("srflx"))
    }

    @Test func `should check the browser at the addresses its offer gives, as a full agent`() {
        let rig = Rig(offer: offerWithCandidate)

        #expect(rig.checks == [browserCandidate])
        #expect(!rig.sender.answer.contains("ice-lite"))
    }

    @Test func `should check again, backing off, until its session is secured`() {
        let rig = Rig(offer: offerWithCandidate)
        rig.pass()
        rig.pass()
        #expect(rig.checks.count == 3)

        rig.goLive()
        rig.pass()

        #expect(rig.checks.count == 3)
    }

    @Test func `should keep sending where the browser nominated, whatever path checks it later`() throws {
        let rig = Rig()
        let browserICE = ICECredentials(ufrag: "h6vY", password: "browserpasswordbrowserpass")
        let other = DatagramAddress(ip: [198, 51, 100, 4], port: 50001)
        func check(nominating: Bool) -> Data {
            STUNMessage.check(from: browserICE, to: ours, priority: 1, tieBreaker: 1,
                              transactionID: (0..<12).map { _ in UInt8.random(in: 0...255) }, nominating: nominating)
        }

        rig.deliver(check(nominating: true), from: browser)
        rig.deliver(check(nominating: false), from: other)
        rig.deliver(dtlsHello, from: browser)

        #expect(rig.sender.state == .live)
    }

    @Test func `should stay ICE-lite and check no one when the offer gives no addresses`() {
        let rig = Rig()

        #expect(rig.checks.isEmpty)
        #expect(rig.sender.answer.contains("a=ice-lite"))
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
