import CoreMedia
import CoreVideo
import Foundation
import IOSurface

/// Real-time video encoder, for whichever `Codec` it is given (H.264 by
/// default) — codec-blind itself. Submission is fire-and-forget — the caller
/// hands a frame in, the encoder hands an `Encoded` chunk back when the
/// compression session is ready, on the session's own queue. Steady output
/// cadence even when individual frames take 5 ms (P) or 50 ms (IDR) — the
/// caller never blocks on encoder slowness.
///
/// It decides; the `CompressionSession` only compresses: when a session
/// opens (the first frame, a new size), which tuning it must accept, which
/// frames are keyframes, and which of the session's answers become a frame.
public final class VideoEncoder: @unchecked Sendable {
    public struct Encoded: Sendable {
        /// The codec's decoder configuration record, as its encoder made it
        /// (`avcC`, `hvcC`) — emitted once, on a new chain's first keyframe.
        public let description: Data?
        /// Keyframe (IDR) or delta (non-IDR P-frame).
        public let kind: Kind
        /// Length-prefixed AVCC NAL bytes.
        public let avcc: Data

        public enum Kind: Sendable { case keyframe, delta }

        public init(description: Data?, kind: Kind, avcc: Data) {
            self.description = description
            self.kind = kind
            self.avcc = avcc
        }
    }

    private let lock = NSLock()
    /// Set by the owner after init when the callback needs to capture
    /// `self`. Calls fire on the session's queue.
    public var onEncoded: (@Sendable (Encoded) -> Void)?

    private let session: any CompressionSession
    private var open = false
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var fps: Int32
    private var bitrate: Int
    private let tuning: H264Tuning
    /// What makes this encoder H.264 or H.265: everything else here is codec-blind.
    let codec: any Codec
    private var referenceChain = H264ReferenceChain()
    private var timeline = H264Timeline()

    public convenience init(
        fps: Int, bitrate: Int = 2_000_000, tuning: H264Tuning = .lowLatency, codec: any Codec = H264Codec(),
        onEncoded: (@Sendable (Encoded) -> Void)? = nil
    ) {
        self.init(fps: fps, bitrate: bitrate, tuning: tuning, codec: codec, session: VideoToolboxSession(),
                  onEncoded: onEncoded)
    }

    init(
        fps: Int, bitrate: Int = 2_000_000, tuning: H264Tuning = .lowLatency, codec: any Codec = H264Codec(),
        session: any CompressionSession, onEncoded: (@Sendable (Encoded) -> Void)? = nil
    ) {
        self.fps = Int32(fps)
        self.bitrate = bitrate
        self.tuning = tuning
        self.codec = codec
        self.session = session
        self.onEncoded = onEncoded
    }

    deinit {
        if open { session.close() }
    }

    public func setBitrate(_ bps: Int) throws {
        guard bps > 0 else { throw EncodingFailure(operation: "set bitrate", status: Self.parameterError) }
        lock.lock()
        defer { lock.unlock() }
        if open {
            let status = session.set(.averageBitRate(bps))
            guard status == 0 else { throw EncodingFailure(operation: "set bitrate", status: status) }
        }
        bitrate = bps
    }

    /// Retune the live session without resetting its reference chain or timeline.
    public func setFrameRate(_ value: Int) throws {
        guard let rate = Int32(exactly: value), rate > 0 else {
            throw EncodingFailure(operation: "set frame rate", status: Self.parameterError)
        }
        if open {
            for property in tuning.frameRateProperties(fps: rate) {
                let status = session.set(property)
                guard status == 0 else { throw EncodingFailure(operation: "set \(property)", status: status) }
            }
        }
        fps = rate
    }

    /// Submit a surface for encoding, wrapped zero-copy into a pixel buffer;
    /// for the downscaled path use the `CVPixelBuffer` overload directly.
    public func encode(_ surface: IOSurface, forceKeyframe: Bool = false) {
        guard let pixelBuffer = PixelBuffer.wrapping(surface) else { return }
        encode(pixelBuffer, forceKeyframe: forceKeyframe)
    }

    /// Submit a pixel buffer for encoding. Returns immediately; output
    /// fires on the session's queue. Tuning is best-effort: a property the
    /// session refuses is skipped, since nobody waits on this frame.
    public func encode(_ pixelBuffer: CVPixelBuffer, forceKeyframe: Bool = false) {
        encode(pixelBuffer, forceKeyframe: forceKeyframe, strict: false) { [weak self] result in
            if case .success(let encoded?) = result { self?.onEncoded?(encoded) }
        }
    }

    /// The completion belongs to this exact submission, including failures;
    /// a session that refuses any of its tuning fails it.
    public func encode(
        _ pixelBuffer: CVPixelBuffer, forceKeyframe: Bool = false,
        completion: @escaping @Sendable (Result<Encoded?, any Error>) -> Void
    ) {
        encode(pixelBuffer, forceKeyframe: forceKeyframe, strict: true, completion: completion)
    }

    public func stop() {
        lock.withLock { referenceChain.reset() }
        if open { session.close() }
        open = false
    }

    private func encode(
        _ pixelBuffer: CVPixelBuffer, forceKeyframe: Bool, strict: Bool,
        completion: @escaping @Sendable (Result<Encoded?, any Error>) -> Void
    ) {
        let w = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let h = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if !open || w != width || h != height {
            width = w
            height = h
            do { try reopen(strict: strict) } catch {
                completion(.failure(error))
                return
            }
        }

        let (generation, needsKeyframe) = lock.withLock { (referenceChain.generation, referenceChain.needsKeyframe) }
        let status = session.submit(
            pixelBuffer, at: timeline.next(fps: fps), keyframe: forceKeyframe || needsKeyframe
        ) { [weak self] result in
            guard let self else { return }
            completion(output(generation: generation, result: result))
        }
        if status != 0 { completion(.failure(EncodingFailure(operation: "submit frame", status: status))) }
    }

    /// What one of the session's answers becomes: nothing for a stale
    /// session, a dropped frame or a frame its reference chain can't take
    /// yet; a failure for an encoder error; otherwise the frame, with the
    /// avcC record when it starts a chain.
    func output(generation: Int, result: CompressionResult) -> Result<Encoded?, any Error> {
        lock.withLock {
            guard generation == referenceChain.generation else { return .success(nil) }
            guard result.status == 0 else {
                return .failure(EncodingFailure(operation: "encode frame output", status: result.status))
            }
            guard !result.dropped, let frame = result.frame else { return .success(nil) }
            var description: Data?
            if frame.keyframe, referenceChain.needsKeyframe {
                description = frame.records[codec.recordAtom]
            }
            guard
                referenceChain.accepts(
                    generation: generation, keyframe: frame.keyframe, hasDescription: description != nil)
            else { return .success(nil) }
            return .success(Encoded(description: description, kind: frame.keyframe ? .keyframe : .delta, avcc: frame.avcc))
        }
    }

    private func reopen(strict: Bool) throws {
        lock.withLock { referenceChain.reset() }
        if open { session.close() }
        open = false

        // Low-latency rate control is chosen when the session opens; the
        // rest of the tuning is set on it afterwards.
        let status = session.open(width: width, height: height, codec: codec.codecType,
                                  lowLatencyRateControl: tuning.lowLatencyRateControl)
        guard status == 0 else { throw EncodingFailure(operation: "create session", status: status) }
        for property in tuning.properties(bitrate: bitrate, fps: fps, profile: codec.profile) {
            let status = session.set(property)
            if strict, status != 0 {
                session.close()
                throw EncodingFailure(operation: "set \(property)", status: status)
            }
        }
        let prepared = session.prepare()
        if strict, prepared != 0 {
            session.close()
            throw EncodingFailure(operation: "prepare session", status: prepared)
        }
        open = true
    }

    /// VideoToolbox's `kVTParameterErr`.
    private static let parameterError: Int32 = -12902

    private struct EncodingFailure: Error, CustomStringConvertible {
        let operation: String
        let status: Int32
        var description: String { "video \(operation) failed (\(status))" }
    }
}
