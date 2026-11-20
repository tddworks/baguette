import Foundation

/// One browser's WebRTC session, sending: it answers the browser's offer as an
/// ICE-lite, DTLS-passive sender, then lives through
/// `connecting → securing → live → hungUp`:
///
/// - **connecting**: until a connectivity check names its ufrag and is signed
///   with its password; that check says where the browser is.
/// - **securing**: DTLS from that address only, until the handshake exports
///   the SRTP keys; then it asks its owner for a keyframe and goes live.
/// - **live**: every frame it is given leaves as SRTP, its packets spaced by a
///   `Pacer` at the target bitrate; a lost picture asks its owner for a
///   keyframe, lost packets are resent as they were sent. Its
///   `CongestionControl` stamps every packet and reads the browser's feedback;
///   the bitrate it then wants goes to its owner, who decides what the encoder
///   makes.
/// - **hungUp**: by request, a failed handshake, or 30 s without a check; it
///   tells its owner once and never sends again.
///
/// One UDP port carries it all, told apart by the first byte (RFC 7983). It
/// knows frames, never where they come from.
public final class WebRTCSender: @unchecked Sendable {
    public enum State: Equatable, Sendable { case connecting, securing, live, hungUp }

    private struct OutboundPacket: Sendable {
        let rtp: RTPPacket
        let endsKeyframe: Bool
    }

    /// Consent freshness (RFC 7675): a browser that stops checking has gone.
    public static let consentTimeout: TimeInterval = 30
    /// Packets kept for a NACK: about a second of a busy screen.
    private static let historySize = 1024

    /// Runs `work` after a delay: how the pacer comes back for its next slice.
    public typealias Schedule = @Sendable (_ after: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Void
    public static let onAQueue: Schedule = { after, work in
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + after, execute: work)
    }

    /// The SDP answer to the browser's offer.
    public let answer: String

    private let lock = NSLock()
    private var current = State.connecting
    private let ice: ICECredentials
    private let ssrc: UInt32
    private let payloadType: UInt8
    private let datagrams: any Datagrams
    private let handshake: any Handshake
    private let congestion: any CongestionControl
    private let encoderBitrate: @Sendable () -> Int
    private weak var events: (any SenderEvents)?
    private let clock: @Sendable () -> Date
    private let started: Date
    private let id: String
    private var lastCheck: Date
    private var browser: DatagramAddress?
    private var srtp: SRTPContext?
    private var sequence: UInt16
    private var history: [UInt16: Data] = [:]
    private var historyOrder: [UInt16] = []
    private let packetizer = H264Packetizer()
    private var pacer: Pacer<OutboundPacket>
    /// Whether the pacer's next slice is already scheduled.
    private var sliceScheduled = false
    private var lastHoldLog: Int64?
    private let schedule: Schedule

    /// `encoderBitrate`: what its owner's encoder makes now — the pacer's rate
    /// while the congestion control has no target of its own. `events` is held
    /// weakly: the owner holds the sender.
    public init(
        offer: SessionDescription,
        ice: ICECredentials = .fresh(),
        ssrc: UInt32 = .random(in: 1...UInt32.max),
        firstSequence: UInt16 = .random(in: 0...UInt16.max),
        datagrams: any Datagrams,
        handshake: any Handshake,
        congestion: any CongestionControl,
        encoderBitrate: @escaping @Sendable () -> Int,
        events: any SenderEvents,
        clock: @escaping @Sendable () -> Date = Date.init,
        schedule: @escaping Schedule = WebRTCSender.onAQueue,
        pacing: Bool = true,
        id: String = UUID().uuidString.lowercased()
    ) {
        self.ice = ice
        self.ssrc = ssrc
        self.payloadType = offer.payloadType
        self.datagrams = datagrams
        self.handshake = handshake
        self.congestion = congestion
        self.encoderBitrate = encoderBitrate
        self.events = events
        self.clock = clock
        self.schedule = schedule
        self.id = id
        self.sequence = firstSequence
        self.started = clock()
        self.lastCheck = started
        self.pacer = Pacer(bitrate: encoderBitrate(), pacing: pacing)
        self.answer = offer.answer(
            ice: ice, fingerprint: handshake.fingerprint, ssrc: ssrc, candidates: datagrams.addresses,
            congestion: congestion.answerLines())
        datagrams.onReceive { [weak self] data, from in self?.receive(data, from: from) }
    }

    public var state: State { lock.withLock { current } }

    /// Whether its pacer spaces its packets (off only for a baseline, `?pacing=off`).
    public var pacing: Bool { lock.withLock { pacer.pacing } }

    public func hangUp() {
        let first = lock.withLock { () -> Bool in
            guard current != .hungUp else { return false }
            current = .hungUp
            return true
        }
        guard first else { return }
        datagrams.close()
        events?.hungUp()
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

    /// A line for its diagnostics, on its timeline: its owner's decisions
    /// (a retune) read beside its own.
    public func note(_ event: String) { record(event, at: microsecondsNow()) }

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
        case .complete?: events?.keyframeNeeded()
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
    /// its congestion control, then tell its owner what follows — a keyframe,
    /// the bitrate the link can take — outside the lock.
    public func act(on asks: [RTCPFeedback]) {
        let result = lock.withLock { () -> (at: Int64, requested: Int, resent: Int, cuts: [BitrateCut], target: Int?)? in
            guard current == .live, let browser else { return nil }
            let now = microsecondsNow()
            var heard = false
            var requested = 0, resent = 0
            var cuts: [BitrateCut] = []
            for ask in asks {
                switch ask {
                case .lost(let sequences):
                    let packets = sequences.compactMap { history[$0] }
                    packets.forEach { datagrams.send($0, to: browser) }
                    requested += sequences.count
                    resent += packets.count
                case .keyframeRequest:
                    continue
                case .transportFeedback, .bandwidthEstimate:
                    if let cut = congestion.heard(ask, at: now) { cuts.append(cut) }
                    heard = true
                }
            }
            return (now, requested, resent, cuts, heard ? congestion.target : nil)
        }
        guard let result else { return }
        if result.requested > 0 {
            record("nack requested=\(result.requested) resent=\(result.resent)", at: result.at)
        }
        result.cuts.forEach { record($0) }
        if asks.contains(.keyframeRequest) {
            record("keyframe requested", at: result.at)
            events?.keyframeNeeded()
        }
        if let target = result.target { events?.estimated(bitrate: target, at: result.at) }
    }

    private func record(_ cut: BitrateCut) {
        let reason: String
        switch cut.cause {
        case .queue(let delay): reason = "queue +\(delay / 1_000) ms"
        case .loss(let share): reason = "\(Int(share * 100)) % lost"
        }
        record("transport-cc cut to \(cut.to / 1_000) kbps: \(reason)", at: cut.at)
    }

    private func record(_ event: String, at now: Int64) {
        let atMs = Int64((started.timeIntervalSince1970 * 1_000).rounded()) + now / 1_000
        events?.diagnostic("[webrtc] \(event) viewer=\(id) atMs=\(atMs)")
    }

    private func microsecondsNow() -> Int64 { Int64(clock().timeIntervalSince(started) * 1_000_000) }

    // MARK: - what leaves

    /// One frame to send: it goes out only while live.
    public func send(_ frame: EncodedFrame) {
        lock.withLock {
            guard current == .live, let browser, srtp != nil else { return }
            let payloads = packetizer.payloads(picture: frame.avcc, parameterSets: frame.isKeyframe ? frame.parameterSets : [])
            let timestamp = UInt32(truncatingIfNeeded: Int64(clock().timeIntervalSince(started) * 90_000))
            let now = microsecondsNow()
            for (index, body) in payloads.enumerated() {
                let packet = RTPPacket(
                    marker: index == payloads.count - 1, payloadType: payloadType,
                    sequence: sequence, timestamp: timestamp, ssrc: ssrc, payload: body)
                let outbound = OutboundPacket(rtp: packet, endsKeyframe: packet.marker && frame.isKeyframe)
                pacer.enqueue(outbound, size: body.count + 12 + 10 + 8, at: now)   // + RTP header, SRTP tag, extension
                sequence &+= 1
            }
            sendPaced(to: browser, at: now)
        }
    }

    /// What the pacer lets out now, each stamped by its congestion control as
    /// it leaves — the send time the estimate reads is the real one — then
    /// another slice in 5 ms while packets wait. Called under the lock.
    private func sendPaced(to browser: DatagramAddress, at now: Int64) {
        pacer.bitrate = congestion.target ?? encoderBitrate()
        let released = pacer.release(at: now)
        // How long what just left actually waited, and the rate it was paced
        // at then: what a bench needs to tell the pacer's delay from the link's.
        if pacer.lastWait > 50_000, lastHoldLog.map({ now - $0 >= 250_000 }) ?? true {
            lastHoldLog = now
            record("pacer held a packet \(pacer.lastWait / 1_000) ms, pacing for \(pacer.bitrate / 1_000) kbps", at: now)
        }
        for outbound in released {
            let packet = outbound.rtp
            let stamped = RTPPacket(
                marker: packet.marker, payloadType: packet.payloadType, sequence: packet.sequence,
                timestamp: packet.timestamp, ssrc: packet.ssrc, payload: packet.payload,
                extensions: congestion.extensions(at: now))
            let wire = srtp!.protect(stamped)
            datagrams.send(wire, to: browser)
            remember(wire, as: packet.sequence)
            congestion.sent(size: wire.count, at: now)
            if outbound.endsKeyframe { record("keyframe sent rtpTimestamp=\(packet.timestamp)", at: now) }
        }
        guard !pacer.isEmpty, !sliceScheduled else { return }
        sliceScheduled = true
        schedule(Double(Pacer<OutboundPacket>.burst) / 1_000_000) { [weak self] in self?.paceAgain() }
    }

    private func paceAgain() {
        lock.withLock {
            sliceScheduled = false
            guard current == .live, let browser else { return }
            sendPaced(to: browser, at: microsecondsNow())
        }
    }

    private func remember(_ wire: Data, as sequence: UInt16) {
        history[sequence] = wire
        historyOrder.append(sequence)
        if historyOrder.count > Self.historySize { history[historyOrder.removeFirst()] = nil }
    }
}
