import Foundation

/// One browser watching one device over WebRTC (WHEP), with a stream of its
/// own. It answers the browser's offer as an ICE-lite, DTLS-passive sender,
/// then lives through `connecting → securing → live → hungUp`:
///
/// - **connecting**: until a connectivity check names its ufrag and is signed
///   with its password; that check says where the browser is.
/// - **securing**: DTLS from that address only, until the handshake exports
///   the SRTP keys; then it asks its stream for a keyframe and goes live.
/// - **live**: every picture leaves as SRTP; a lost picture brings a keyframe,
///   lost packets are resent as they were sent. Its `CongestionControl` stamps
///   every packet, reads the browser's feedback and sets the bitrate it wants;
///   `EncoderRetune` decides when the encoder follows.
/// - **hungUp**: by request, a failed handshake or stream, or 30 s without a
///   check; its stream is stopped and it never sends again.
///
/// One UDP port carries it all, told apart by the first byte (RFC 7983).
public final class WebRTCViewer: @unchecked Sendable {
    public enum State: Equatable, Sendable { case connecting, securing, live, hungUp }

    /// Consent freshness (RFC 7675): a browser that stops checking has gone.
    public static let consentTimeout: TimeInterval = 30
    /// Packets kept for a NACK: about a second of a busy screen.
    private static let historySize = 1024

    /// The SDP answer to the browser's offer.
    public let answer: String

    private let lock = NSLock()
    private var current = State.connecting
    private let ice: ICECredentials
    private let ssrc: UInt32
    private let payloadType: UInt8
    private let datagrams: any Datagrams
    private let handshake: any Handshake
    private var stream: (any Stream)!
    private let clock: @Sendable () -> Date
    private let started: Date
    private var lastCheck: Date
    private var browser: DatagramAddress?
    private var srtp: SRTPContext?
    private var sequence: UInt16
    private var parameterSets: [Data] = []
    private var history: [UInt16: Data] = [:]
    private var historyOrder: [UInt16] = []
    private var hangUpHandlers: [@Sendable () -> Void] = []
    private let packetizer = H264Packetizer()
    private let congestion: any CongestionControl
    private var retune = EncoderRetune()

    public init(
        offer: SessionDescription,
        ice: ICECredentials = .fresh(),
        ssrc: UInt32 = .random(in: 1...UInt32.max),
        firstSequence: UInt16 = .random(in: 0...UInt16.max),
        datagrams: any Datagrams,
        handshake: any Handshake,
        stream makeStream: (any FrameSink) -> any Stream,
        congestion makeControl: (_ startingBitrate: Int) -> any CongestionControl,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.ice = ice
        self.ssrc = ssrc
        self.payloadType = offer.payloadType
        self.datagrams = datagrams
        self.handshake = handshake
        self.clock = clock
        self.sequence = firstSequence
        self.started = clock()
        self.lastCheck = started
        let sink = RTPFrameSink()
        let stream = makeStream(sink)
        let congestion = makeControl(stream.config.bitrateBps)
        self.stream = stream
        self.congestion = congestion
        self.answer = offer.answer(
            ice: ice, fingerprint: handshake.fingerprint, ssrc: ssrc, candidates: datagrams.addresses,
            congestion: congestion.answerLines())
        sink.attach(self)
        datagrams.onReceive { [weak self] data, from in self?.receive(data, from: from) }
    }

    public var state: State { lock.withLock { current } }

    /// Its own stream, which its page retunes (`set_bitrate`, `force_idr`, …)
    /// over its control socket as any stream socket's page does.
    public var ownStream: any Stream { stream }

    /// Starts its own stream on `screen`.
    public func start(on screen: any Screen) throws { try stream.start(on: screen) }

    /// Called once, when it hangs up — at once if it already has.
    public func onHangUp(_ handler: @escaping @Sendable () -> Void) {
        let already = lock.withLock { () -> Bool in
            if current == .hungUp { return true }
            hangUpHandlers.append(handler)
            return false
        }
        if already { handler() }
    }

    public func hangUp() {
        let handlers = lock.withLock { () -> [@Sendable () -> Void]? in
            guard current != .hungUp else { return nil }
            current = .hungUp
            defer { hangUpHandlers = [] }
            return hangUpHandlers
        }
        guard let handlers else { return }
        stream.stop()
        datagrams.close()
        handlers.forEach { $0() }
    }

    /// Time passing: consent runs out after `consentTimeout` without a check;
    /// while securing, DTLS's due records are resent.
    public func tick(now: Date) {
        let expired = lock.withLock { () -> Bool in
            guard current != .hungUp else { return false }
            if now.timeIntervalSince(lastCheck) > Self.consentTimeout { return true }
            if current == .securing, let browser {
                handshake.resend().forEach { datagrams.send($0, to: browser) }
            }
            return false
        }
        if expired { hangUp() }
    }

    // MARK: - what arrives

    func receive(_ data: Data, from address: DatagramAddress) {
        guard let first = data.first else { return }
        switch first {
        case 0...3: check(data, from: address)
        case 20...63: secure(data, from: address)
        case 128...191: feedback(data, from: address)
        default: return
        }
    }

    private func check(_ data: Data, from address: DatagramAddress) {
        guard let answer = STUNMessage(data)?.answer(from: address, ice: ice) else { return }
        lock.withLock {
            guard current != .hungUp else { return }
            browser = address
            lastCheck = clock()
            if current == .connecting { current = .securing }
            datagrams.send(answer, to: address)
        }
    }

    private func secure(_ record: Data, from address: DatagramAddress) {
        let outcome = lock.withLock { () -> HandshakeProgress? in
            guard current == .securing, address == browser else { return nil }
            let progress = handshake.receive(record)
            switch progress {
            case .continuing(let replies):
                replies.forEach { datagrams.send($0, to: address) }
            case .complete(let replies, let export):
                replies.forEach { datagrams.send($0, to: address) }
                guard let keys = SRTPKeys.fromDTLS(export: export) else { return .failed }
                srtp = SRTPContext(local: keys.local, remote: keys.remote)
                current = .live
            case .failed:
                break
            }
            return progress
        }
        switch outcome {
        case .complete?: stream.requestKeyframe()
        case .failed?: hangUp()
        default: break
        }
    }

    private func feedback(_ data: Data, from address: DatagramAddress) {
        // RFC 5761: RTCP packet types sit at 192–223 in the second byte.
        guard data.count > 1, (192...223).contains(data[data.startIndex + 1]) else { return }
        let asks = lock.withLock { () -> [RTCPFeedback] in
            guard current == .live, address == browser, let plain = srtp?.unprotectRTCP(data) else { return [] }
            return RTCPFeedback.parse(plain)
        }
        act(on: asks)
    }

    /// What the browser asked, decrypted: resend what it lost, hand the rest to
    /// its congestion control, and tell the stream what follows — a keyframe, a
    /// retune — outside the lock.
    func act(on asks: [RTCPFeedback]) {
        let retuneTo = lock.withLock { () -> Int? in
            guard current == .live, let browser else { return nil }
            let now = microsecondsNow()
            var heard = false
            for ask in asks {
                switch ask {
                case .lost(let sequences):
                    sequences.compactMap { history[$0] }.forEach { datagrams.send($0, to: browser) }
                case .keyframeRequest:
                    continue
                case .transportFeedback, .bandwidthEstimate:
                    congestion.heard(ask, at: now)
                    heard = true
                }
            }
            guard heard, let target = congestion.target else { return nil }
            return retune.bitrate(for: target, current: stream.config.bitrateBps, now: now)
        }
        if asks.contains(.keyframeRequest) { stream.requestKeyframe() }
        if let retuneTo {
            log("[webrtc] retune \(stream.config.bitrateBps / 1_000) → \(retuneTo / 1_000) kbps")
            try? stream.update(.bitrate(retuneTo))
        }
    }

    private func microsecondsNow() -> Int64 { Int64(clock().timeIntervalSince(started) * 1_000_000) }

    // MARK: - what leaves

    /// One AVCC envelope from its stream: parameter sets are kept for the next
    /// keyframe; a picture goes out only while live.
    func show(_ envelope: Data) {
        guard let (tag, payload) = AVCCEnvelope.unwrap(envelope) else { return }
        lock.withLock {
            if tag == AVCCEnvelope.descriptionTag, let sets = AVCCParameterSets.parse(avcC: payload) {
                parameterSets = sets.sps + sets.pps
                return
            }
            guard tag == AVCCEnvelope.keyframeTag || tag == AVCCEnvelope.deltaTag,
                  current == .live, let browser, srtp != nil else { return }
            let payloads = packetizer.payloads(
                picture: payload, parameterSets: tag == AVCCEnvelope.keyframeTag ? parameterSets : [])
            let timestamp = UInt32(truncatingIfNeeded: Int64(clock().timeIntervalSince(started) * 90_000))
            for (index, body) in payloads.enumerated() {
                let now = microsecondsNow()
                let extensions = congestion.extensions(at: now)
                let packet = RTPPacket(
                    marker: index == payloads.count - 1, payloadType: payloadType,
                    sequence: sequence, timestamp: timestamp, ssrc: ssrc, payload: body, extensions: extensions)
                let wire = srtp!.protect(packet)
                datagrams.send(wire, to: browser)
                remember(wire, as: sequence)
                congestion.sent(size: wire.count, at: now)
                sequence &+= 1
            }
        }
    }

    private func remember(_ wire: Data, as sequence: UInt16) {
        history[sequence] = wire
        historyOrder.append(sequence)
        if historyOrder.count > Self.historySize { history[historyOrder.removeFirst()] = nil }
    }
}
