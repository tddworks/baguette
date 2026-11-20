import Foundation
import Mockable
import Testing
@testable import BaguetteDevice
@testable import protocol BaguetteDevice.Stream

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
private let stranger = DatagramAddress(ip: [10, 0, 0, 9], port: 4444)
private let here = [DatagramAddress(ip: [192, 168, 2, 221], port: 50000)]

/// A DTLS export whose browser half (client key 00…0f, client salt 10…1d) signed
/// the SRTCP below; our half is A0…AF / B0…BD.
private let export: [UInt8] = Array(0..<16) + Array(0xA0..<0xB0) + Array(0x10..<0x1E) + Array(0xB0..<0xBE)
private let pictureLoss = hex("81ce0002000000014caab84e800000078baa6853b620ebd53049")
private let lost1001 = hex("81cd00030000000145b85b873c02672d8000000841fb140e4d8f2e57fb8f")
private let dtlsHello = Data([0x16, 0xFE, 0xFD, 0, 0])

private let sps = Data([0x67, 0x64, 0x00, 0x1F, 0xAC]), pps = Data([0x68, 0xEE, 0x3C, 0x80])
private let avcC = Data([0x01, 0x64, 0x00, 0x1F, 0xFF, 0xE1, 0x00, 0x05]) + sps + Data([0x01, 0x00, 0x04]) + pps
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

/// A viewer wired to mocks, with what it sent and when it thinks it is.
private struct Rig {
    let datagrams = MockDatagrams()
    let handshake = MockHandshake()
    let stream = MockStream()
    let congestion = MockCongestionControl()
    let sent = Box<[(Data, DatagramAddress)]>([])
    let received = Box<(@Sendable (Data, DatagramAddress) -> Void)?>(nil)
    let now = Box(Date(timeIntervalSince1970: 1_000))
    let sink = Box<(any FrameSink)?>(nil)
    let viewer: WebRTCViewer

    init(
        progress: HandshakeProgress = .complete(replies: [], srtpExport: export),
        target: Int? = nil, stamp: [RTPHeaderExtension] = [], answerLines: [String] = []
    ) {
        given(datagrams).addresses.willReturn(here)
        given(datagrams).send(.any, to: .any).willProduce { [sent] data, to in sent.value.append((data, to)) }
        given(datagrams).onReceive(.any).willProduce { [received] handler in received.value = handler }
        given(datagrams).close().willReturn()
        given(handshake).fingerprint.willReturn("sha-256 AA:BB")
        given(handshake).receive(.any).willReturn(progress)
        given(handshake).resend().willReturn([Data([0x16, 0xFE, 0xFD, 9])])
        given(stream).requestKeyframe().willReturn()
        given(stream).stop().willReturn()
        given(stream).config.willReturn(.default)
        given(stream).update(.any).willReturn()
        given(congestion).answerLines().willReturn(answerLines)
        given(congestion).extensions(at: .any).willReturn(stamp)
        given(congestion).sent(size: .any, at: .any).willReturn()
        given(congestion).heard(.any, at: .any).willReturn()
        given(congestion).target.willReturn(target)
        let (stream, sink, now, congestion) = (stream, sink, now, congestion)
        viewer = WebRTCViewer(
            offer: offer, ice: ours, ssrc: 0xCAFE_BABE, firstSequence: 1000,
            datagrams: datagrams, handshake: handshake,
            stream: { frames in sink.value = frames; return stream },
            congestion: { _ in congestion },
            clock: { now.value })
    }

    func deliver(_ data: Data, from address: DatagramAddress = browser) { received.value?(data, address) }

    func goLive() { deliver(check); deliver(dtlsHello) }

    func show(_ envelope: Data) { sink.value?.write(envelope) }

    var packets: [RTPPacket] { sent.value.compactMap { RTPPacket($0.0) }.filter { !RTPPacket.isRTCP($0.data) } }
}

@Suite("WebRTCViewer")
struct WebRTCViewerTests {
    @Test func `should answer the offer with its ICE credentials, the handshake's fingerprint and the socket's addresses`() {
        let rig = Rig()

        #expect(rig.viewer.answer == offer.answer(
            ice: ours, fingerprint: "sha-256 AA:BB", ssrc: 0xCAFE_BABE, candidates: here))
        #expect(rig.viewer.state == .connecting)
    }

    @Test func `should answer the browser's connectivity check and learn where it is`() throws {
        let rig = Rig()

        rig.deliver(check)

        let answer = try #require(STUNMessage(check)?.answer(from: browser, ice: ours))
        #expect(rig.sent.value.map(\.0) == [answer])
        #expect(rig.sent.value.map(\.1) == [browser])
        #expect(rig.viewer.state == .securing)
    }

    @Test func `should not answer a check meant for another viewer`() {
        let rig = Rig()
        var forged = check
        forged[forged.count - 30] ^= 1   // inside MESSAGE-INTEGRITY

        rig.deliver(forged)

        #expect(rig.sent.value.isEmpty)
        #expect(rig.viewer.state == .connecting)
    }

    @Test func `should hand the browser's DTLS records to the handshake and send its replies back`() {
        let rig = Rig(progress: .continuing(replies: [Data([0x16, 0xFE, 0xFD, 1])]))

        rig.goLive()

        #expect(rig.sent.value.last?.0 == Data([0x16, 0xFE, 0xFD, 1]))
        #expect(rig.sent.value.last?.1 == browser)
        #expect(rig.viewer.state == .securing)
    }

    @Test func `should take DTLS only from the browser that passed its check`() {
        let rig = Rig()

        rig.deliver(dtlsHello)
        rig.deliver(check)
        rig.deliver(dtlsHello, from: stranger)

        verify(rig.handshake).receive(.any).called(0)
        #expect(rig.viewer.state == .securing)
    }

    @Test func `should go live and ask its stream for a keyframe when the handshake completes`() {
        let rig = Rig()

        rig.goLive()

        #expect(rig.viewer.state == .live)
        verify(rig.stream).requestKeyframe().called(1)
    }

    @Test func `should hang up and stop its stream when the handshake fails`() {
        let rig = Rig(progress: .failed)

        rig.goLive()

        #expect(rig.viewer.state == .hungUp)
        verify(rig.stream).stop().called(1)
        verify(rig.datagrams).close().called(1)
    }

    @Test func `should send no picture before it is live`() {
        let rig = Rig(progress: .continuing(replies: []))
        rig.deliver(check)

        rig.show(AVCCEnvelope.description(avcc: avcC))
        rig.show(AVCCEnvelope.keyframe(avcc: picture(Data([0x65, 1, 2, 3]))))

        #expect(rig.packets.isEmpty)
    }

    @Test func `should send a keyframe as SRTP packets once live, its parameter sets first and its last packet marked`() {
        let rig = Rig()
        rig.goLive()
        rig.now.value = Date(timeIntervalSince1970: 1_001)

        rig.show(AVCCEnvelope.description(avcc: avcC))
        rig.show(AVCCEnvelope.keyframe(avcc: picture(Data([0x65, 1, 2, 3]))))

        let packets = rig.packets
        #expect(packets.map(\.sequence) == [1000, 1001])
        #expect(packets.map(\.marker) == [false, true])
        #expect(packets.allSatisfy { $0.ssrc == 0xCAFE_BABE && $0.payloadType == 112 && $0.timestamp == 90_000 })
        // STAP-A (1 + 2 + 5 + 2 + 4) and the slice (4), each encrypted, plus a 10-byte tag.
        #expect(packets.map(\.payload.count) == [14 + 10, 4 + 10])
    }

    @Test func `should ask for a keyframe when the browser reports a lost picture`() {
        let rig = Rig()
        rig.goLive()

        rig.deliver(pictureLoss)

        verify(rig.stream).requestKeyframe().called(2)
    }

    @Test func `should resend the packets the browser reports lost, as they were sent`() throws {
        let rig = Rig()
        rig.goLive()
        rig.show(AVCCEnvelope.description(avcc: avcC))
        rig.show(AVCCEnvelope.keyframe(avcc: picture(Data([0x65, 1, 2, 3]))))
        let first = try #require(rig.sent.value.first { RTPPacket($0.0)?.sequence == 1001 }).0

        rig.deliver(lost1001)

        #expect(rig.sent.value.last?.0 == first)
    }

    @Test func `should hang up when the browser stops checking for 30 seconds`() {
        let rig = Rig()
        rig.goLive()

        rig.viewer.tick(now: Date(timeIntervalSince1970: 1_029))
        #expect(rig.viewer.state == .live)
        rig.viewer.tick(now: Date(timeIntervalSince1970: 1_031))
        #expect(rig.viewer.state == .hungUp)
        verify(rig.stream).stop().called(1)
    }

    @Test func `should resend its handshake records when DTLS's timer says they are due`() {
        let rig = Rig(progress: .continuing(replies: []))
        rig.goLive()

        rig.viewer.tick(now: Date(timeIntervalSince1970: 1_001))

        #expect(rig.sent.value.last?.0 == Data([0x16, 0xFE, 0xFD, 9]))
    }

    @Test func `should never send again, nor stop its stream twice, once hung up`() {
        let rig = Rig()
        rig.goLive()

        rig.viewer.hangUp()
        rig.viewer.hangUp()
        rig.show(AVCCEnvelope.description(avcc: avcC))
        rig.show(AVCCEnvelope.keyframe(avcc: picture(Data([0x65, 1, 2, 3]))))
        rig.deliver(check)

        #expect(rig.packets.isEmpty)
        #expect(rig.viewer.state == .hungUp)
        verify(rig.stream).stop().called(1)
        verify(rig.datagrams).close().called(1)
    }

    @Test func `should hang up when its stream fails`() async throws {
        let rig = Rig()
        rig.goLive()

        rig.sink.value?.fail(CancellationError())

        // Off the stream's queue, so a moment later.
        for _ in 0..<100 where rig.viewer.state != .hungUp { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rig.viewer.state == .hungUp)
    }

    @Test func `should start its own stream on the screen it is given`() throws {
        let rig = Rig()
        let screen = MockScreen()
        given(rig.stream).start(on: .any).willReturn()

        try rig.viewer.start(on: screen)

        verify(rig.stream).start(on: .any).called(1)
    }

    @Test func `should hang up when the handshake hands over keys of the wrong size`() {
        let rig = Rig(progress: .complete(replies: [], srtpExport: [1, 2, 3]))

        rig.goLive()

        #expect(rig.viewer.state == .hungUp)
        verify(rig.stream).requestKeyframe().called(0)
    }

    @Test func `should read past bytes that are none of STUN, DTLS or SRTP`() {
        let rig = Rig()
        rig.goLive()

        rig.deliver(Data())
        rig.deliver(Data([0x40, 0x00]))
        rig.deliver(Data([0x80, 0x60, 0x00]))   // RTP from the browser: a viewer only sends

        #expect(rig.sent.value.count == 1)    // the check's answer, and nothing since
        #expect(rig.viewer.state == .live)
    }

    @Test func `should tell at once someone who asks after it has hung up`() {
        let rig = Rig()
        let told = Box(0)
        rig.viewer.hangUp()

        rig.viewer.onHangUp { told.value += 1 }

        #expect(told.value == 1)
    }

    @Test func `should tell whoever keeps it once it hangs up`() {
        let rig = Rig()
        let told = Box(0)
        rig.viewer.onHangUp { told.value += 1 }

        rig.viewer.hangUp()

        #expect(told.value == 1)
    }

    @Test func `should answer with the lines its congestion control needs`() {
        let rig = Rig(answerLines: ["a=extmap:9 http://example/ext"])

        #expect(rig.viewer.answer.contains("a=extmap:9 http://example/ext\r\n"))
    }

    @Test func `should stamp every packet with what its congestion control asks, and report it sent`() {
        let rig = Rig(stamp: [RTPHeaderExtension(id: 9, data: [7])])
        rig.goLive()

        rig.show(AVCCEnvelope.description(avcc: avcC))
        rig.show(AVCCEnvelope.keyframe(avcc: picture(Data([0x65, 1, 2, 3]))))

        #expect(rig.packets.map(\.extensions) == [[RTPHeaderExtension(id: 9, data: [7])], [RTPHeaderExtension(id: 9, data: [7])]])
        verify(rig.congestion).sent(size: .any, at: .any).called(2)
    }

    @Test func `should hand the browser's feedback to its congestion control and retune to its target`() {
        let rig = Rig(target: 4_000_000)
        rig.goLive()

        rig.viewer.act(on: [.bandwidthEstimate(bitsPerSecond: 4_000_000)])

        verify(rig.congestion).heard(.any, at: .any).called(1)
        verify(rig.stream).update(.value(.bitrate(4_000_000))).called(1)
    }

    @Test func `should leave its encoder alone while its congestion control wants no bitrate`() {
        let rig = Rig(target: nil)
        rig.goLive()

        rig.viewer.act(on: [.bandwidthEstimate(bitsPerSecond: 1_000_000)])

        verify(rig.stream).update(.any).called(0)
    }
}

/// A stream that, like AVCCStream, fails from its own serial queue and stops
/// with `queue.sync` — and says whether it was asked to stop from inside it,
/// which would deadlock (libdispatch traps on it).
private final class SerialStream: Stream, @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.serial-stream")
    private let key = DispatchSpecificKey<Bool>()
    private let lock = NSLock()
    private var sink: (any FrameSink)?
    private var _stoppedFromOwnQueue = false
    private var _stopped = false
    let config = StreamConfig.default

    init(sink: any FrameSink) {
        self.sink = sink
        queue.setSpecific(key: key, value: true)
    }

    var stoppedFromOwnQueue: Bool { lock.withLock { _stoppedFromOwnQueue } }
    var stopped: Bool { lock.withLock { _stopped } }

    func failFromItsQueue() {
        queue.sync { sink?.fail(CancellationError()) }
    }

    func start(on screen: any Screen) throws {}
    func stop() {
        if DispatchQueue.getSpecific(key: key) == true {
            lock.withLock { _stoppedFromOwnQueue = true }
            return
        }
        queue.sync {}
        lock.withLock { _stopped = true }
    }
    func apply(_ config: StreamConfig) throws {}
    func update(_ change: StreamConfig.Change) throws {}
    func requestKeyframe() {}
    func requestSnapshot() {}
}

@Suite("WebRTCViewer when its stream fails")
struct WebRTCViewerStreamFailureTests {
    @Test func `should hang up when its stream fails, without stopping the stream from inside its own queue`() async throws {
        let datagrams = MockDatagrams()
        given(datagrams).addresses.willReturn(here)
        given(datagrams).onReceive(.any).willReturn()
        given(datagrams).close().willReturn()
        let handshake = MockHandshake()
        given(handshake).fingerprint.willReturn("sha-256 AA:BB")
        let made = Box<SerialStream?>(nil)
        let viewer = WebRTCViewer(
            offer: offer, ice: ours, datagrams: datagrams, handshake: handshake,
            stream: { sink in let stream = SerialStream(sink: sink); made.value = stream; return stream },
            congestion: { _ in FixedBitrate() })

        made.value?.failFromItsQueue()

        for _ in 0..<100 where viewer.state != .hungUp { try await Task.sleep(for: .milliseconds(10)) }
        #expect(viewer.state == .hungUp)
        #expect(made.value?.stoppedFromOwnQueue == false)
        #expect(made.value?.stopped == true)
    }
}
