import Foundation
import WebRTCKit

/// One browser watching one device over WebRTC (WHEP): a `WebRTCSender` — the
/// session, from the offer to the packets on the wire — fed by a stream of
/// its own. What the viewer adds is the device side:
///
/// - its stream encodes in the codec its session was answered with;
/// - each AVCC envelope its stream makes becomes an `EncodedFrame` (a
///   keyframe carries the stream's latest parameter sets, read out of the
///   record with the codec its session was answered with);
/// - a keyframe the sender needs is asked of the stream;
/// - the bitrate the link can take reaches the encoder when `EncoderRetune`
///   says so;
/// - when the session ends, for whatever reason, its stream is stopped.
public final class WebRTCViewer: @unchecked Sendable {
    public typealias State = WebRTCSender.State
    public typealias Schedule = WebRTCSender.Schedule
    public static let consentTimeout = WebRTCSender.consentTimeout
    public static let onAQueue = WebRTCSender.onAQueue

    private let lock = NSLock()
    private var stream: (any Stream)!
    private var sender: WebRTCSender!
    private let events = Events()
    private let diagnose: @Sendable (String) -> Void
    /// The codec its session was answered with: how its records are read.
    private let codec: any Codec
    private var parameterSets: [Data] = []
    private var retune = EncoderRetune()
    private var hungUp = false
    private var hangUpHandlers: [@Sendable () -> Void] = []

    public init(
        offer: SessionDescription,
        ice: ICECredentials = .fresh(),
        ssrc: UInt32 = .random(in: 1...UInt32.max),
        firstSequence: UInt16 = .random(in: 0...UInt16.max),
        datagrams: any Datagrams,
        handshake: any Handshake,
        stream makeStream: (any FrameSink, any Codec) -> any Stream,
        congestion makeControl: (_ startingBitrate: Int) -> any CongestionControl,
        clock: @escaping @Sendable () -> Date = Date.init,
        schedule: @escaping Schedule = WebRTCViewer.onAQueue,
        reflexive: DatagramAddress? = nil,
        relay: DatagramAddress? = nil,
        pacing: Bool = true,
        id: String = UUID().uuidString.lowercased(),
        diagnose: @escaping @Sendable (String) -> Void = log
    ) {
        self.diagnose = diagnose
        codec = Codecs.of(offer.codec.kind)
        let sink = RTPFrameSink()
        // Its encoder makes exactly the codec its sender was answered with.
        let stream = makeStream(sink, codec)
        self.stream = stream
        sender = WebRTCSender(
            offer: offer, ice: ice, ssrc: ssrc, firstSequence: firstSequence,
            datagrams: datagrams, handshake: handshake,
            congestion: makeControl(stream.config.bitrateBps),
            encoderBitrate: { [unowned self] in self.stream.config.bitrateBps },
            events: events, clock: clock, schedule: schedule, reflexive: reflexive, relay: relay, pacing: pacing, id: id)
        events.viewer = self
        sink.attach(self)
        // Which codec it sends, of those the browser offered: how a browser's
        // H.265 support shows up in the server's log.
        diagnose("[webrtc] viewer \(id) sends \(Self.named(offer.codec)) (offered: \(offer.offered.map(Self.named).joined(separator: ", ")))")
    }

    private static func named(_ codec: VideoCodec) -> String {
        switch codec {
        case let .h264(_, profileLevelID): "\(codec.rtpmap) profile-level-id=\(profileLevelID)"
        case let .h265(_, profileID, _, _): "\(codec.rtpmap) profile-id=\(profileID)"
        }
    }

    /// The SDP answer to the browser's offer.
    public var answer: String { sender.answer }

    public var state: State { sender.state }

    /// Whether its sender paces its packets (off only for the bench's baseline, `?pacing=off`).
    public var pacing: Bool { sender.pacing }

    /// Its own stream, which its page retunes (`set_bitrate`, `force_idr`, …)
    /// over its control socket as any stream socket's page does.
    public var ownStream: any Stream { stream }

    /// Starts its own stream on `screen`.
    public func start(on screen: any Screen) throws { try stream.start(on: screen) }

    /// Called once, when it hangs up — at once if it already has.
    public func onHangUp(_ handler: @escaping @Sendable () -> Void) {
        let already = lock.withLock { () -> Bool in
            if hungUp { return true }
            hangUpHandlers.append(handler)
            return false
        }
        if already { handler() }
    }

    public func hangUp() { sender.hangUp() }

    /// Time passing: the sender's consent and handshake timers.
    public func tick(now: Date) { sender.tick(now: now) }

    /// What the browser asked, decrypted (see `WebRTCSender.act(on:)`).
    func act(on asks: [RTCPFeedback]) { sender.act(on: asks) }

    // MARK: - its stream

    /// One AVCC envelope from its stream: the parameter sets in a record are
    /// kept for the next keyframe; a picture goes to the sender.
    func show(_ envelope: Data) {
        guard let (tag, payload) = AVCCEnvelope.unwrap(envelope) else { return }
        if tag == AVCCEnvelope.descriptionTag, let sets = codec.parameterSets(record: payload) {
            lock.withLock { parameterSets = sets }
            return
        }
        guard tag == AVCCEnvelope.keyframeTag || tag == AVCCEnvelope.deltaTag else { return }
        let isKeyframe = tag == AVCCEnvelope.keyframeTag
        let sets = isKeyframe ? lock.withLock { parameterSets } : []
        sender.send(EncodedFrame(avcc: payload, isKeyframe: isKeyframe, parameterSets: sets))
    }

    // MARK: - what its sender tells it

    fileprivate func keyframeNeeded() { stream.requestKeyframe() }

    /// The link's bitrate: the encoder follows when `EncoderRetune` says so.
    fileprivate func estimated(bitrate target: Int, at now: Int64) {
        let from = stream.config.bitrateBps
        guard let to = lock.withLock({ retune.bitrate(for: target, current: from, now: now) }) else { return }
        do {
            try stream.update(.bitrate(to))
            sender.note("retune \(from / 1_000) → \(to / 1_000) kbps")
        } catch {
            sender.note("retune to \(to / 1_000) kbps failed: \(error)")
        }
    }

    fileprivate func sessionEnded() {
        let handlers = lock.withLock { () -> [@Sendable () -> Void]? in
            guard !hungUp else { return nil }
            hungUp = true
            defer { hangUpHandlers = [] }
            return hangUpHandlers
        }
        guard let handlers else { return }
        stream.stop()
        handlers.forEach { $0() }
    }

    fileprivate func note(_ line: String) { diagnose(line) }
}

/// The viewer as its sender's owner — kept apart so these calls aren't the
/// viewer's public face. The sender holds it weakly, the viewer strongly.
private final class Events: SenderEvents, @unchecked Sendable {
    weak var viewer: WebRTCViewer?

    func keyframeNeeded() { viewer?.keyframeNeeded() }
    func estimated(bitrate: Int, at now: Int64) { viewer?.estimated(bitrate: bitrate, at: now) }
    func hungUp() { viewer?.sessionEnded() }
    func diagnostic(_ line: String) { viewer?.note(line) }
}
