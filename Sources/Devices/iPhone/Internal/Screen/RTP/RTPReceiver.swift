import BaguetteDevice
import Foundation
import IOSurface

/// baguette's own receiver for a phone's screen: our H.264 offer
/// (`MediaStreamOffer` — AVConference's fields minus HEVC, which mosaics
/// under motion), the phone's RTP made into frames (`VideoDepacketizer`),
/// nothing decoded until a keyframe after a loss (`DecodeGate`), our RTCP
/// back (`ReceiverFeedback`), and VideoToolbox decoding, cropped to the
/// screen (`StreamDecoder`). All of it pure values but the decoder.
///
/// `receive` and `nextReport` run on two threads; what they share is
/// guarded, and decoding happens outside the guard.
final class RTPReceiver: ScreenReceiver, @unchecked Sendable {
    private let makeDecoder: @Sendable () -> any StreamDecoder
    private let mac: @Sendable () -> MediaStreamOffer.Mac
    private let now: @Sendable () -> Date
    private let pause: @Sendable () -> Void
    private let lock = NSLock()
    private var feedback: ReceiverFeedback?
    private var depacketizer = VideoDepacketizer()
    private var gate = DecodeGate()
    private var parameterSets: [Data] = []
    private var decoder: (any StreamDecoder)?
    private var screen: Size?
    private var onPicture: (@Sendable (IOSurface) -> Void)?
    private var opened: Date?
    private var reports: [Data] = []

    init(makeDecoder: @escaping @Sendable () -> any StreamDecoder = { VTStreamDecoder() },
         mac: @escaping @Sendable () -> MediaStreamOffer.Mac = { HostNetwork.mac },
         now: @escaping @Sendable () -> Date = { Date() },
         pause: @escaping @Sendable () -> Void = { Thread.sleep(forTimeInterval: 0.02) }) {
        self.makeDecoder = makeDecoder
        self.mac = mac
        self.now = now
        self.pause = pause
    }

    func offer() throws -> Data {
        MediaStreamOffer(receiver: UInt32.random(in: 1 ... .max), host: mac(),
                         made: MediaStreamSession.ntpTime(now())).bytes
    }

    /// The two sources in CoreDevice's answer: the phone's, and ours as its receiver.
    func accept(_ answer: [String: Any]) throws {
        guard let session = MediaStreamSession(answer: answer) else { throw PhoneScreen.StreamError.unexpectedAnswer }
        lock.withLock { feedback = ReceiverFeedback(reporter: session.ourSource, source: session.phoneSource) }
    }

    func start(croppedTo screen: Size?, onPicture: @escaping @Sendable (IOSurface) -> Void) throws {
        lock.withLock {
            self.screen = screen
            self.onPicture = onPicture
            opened = now()
        }
    }

    func receive(_ datagram: Data) {
        guard !RTPPacket.isRTCP(datagram), let packet = RTPPacket(datagram) else { return }
        let (configure, decode) = lock.withLock { () -> ([Data]?, Data?) in
            reports += feedback?.heard(packet) ?? []
            guard let unit = depacketizer.push(packet) else { return (nil, nil) }
            let fresh = unit.parameterSets
            let configure = !fresh.isEmpty && fresh != parameterSets ? fresh : nil
            if let configure { parameterSets = configure }
            guard gate.admits(unit, droppedSince: depacketizer.droppedFrames), !parameterSets.isEmpty else {
                return (configure, nil)
            }
            return (configure, unit.lengthPrefixedFrame)
        }
        if let configure { configureDecoder(with: configure) }
        if let decode { lock.withLock { decoder }?.decode(decode) }
    }

    /// Whatever is due: replies to what was heard, then the periodic report
    /// (asking for a keyframe while none has come).
    func nextReport() -> Data? {
        let next = lock.withLock { () -> Data? in
            if reports.isEmpty, let opened {
                reports += feedback?.due(at: now().timeIntervalSince(opened), wantingKeyframe: gate.needsKeyframe) ?? []
            }
            return reports.isEmpty ? nil : reports.removeFirst()
        }
        if next == nil { pause() }
        return next
    }

    func stop() {
        let decoder = lock.withLock { defer { self.decoder = nil }; return self.decoder }
        decoder?.stop()
    }

    private func configureDecoder(with parameterSets: [Data]) {
        let (existing, screen, onPicture) = lock.withLock { (decoder, screen, onPicture) }
        guard let onPicture else { return }
        let decoder = existing ?? makeDecoder()
        do {
            try decoder.configure(parameterSets: parameterSets, screen: screen, onFrame: onPicture)
            lock.withLock { self.decoder = decoder }
        } catch {
            log("[coredevice] the phone's H.264 couldn't be decoded: \(error)")
        }
    }
}
