import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import VideoToolbox

/// Real-time H.264 encoder backed by `VTCompressionSession`. Submission is
/// fire-and-forget — the caller hands a surface in, the encoder hands an
/// `Encoded` chunk back via the output handler when VT is ready, on VT's
/// own queue. Steady output cadence even when individual frames take
/// 5 ms (P) or 50 ms (IDR) — the caller never blocks on encoder slowness.
final class H264Encoder: @unchecked Sendable {
    struct Encoded: Sendable {
        /// avcC parameter-set blob — emitted exactly once on the first IDR.
        let description: Data?
        /// Keyframe (IDR) or delta (non-IDR P-frame).
        let kind: Kind
        /// Length-prefixed AVCC NAL bytes.
        let avcc: Data

        enum Kind: Sendable { case keyframe, delta }
    }

    private let lock = NSLock()
    /// Set by the owner after init when the callback needs to capture
    /// `self`. Calls fire on VT's internal queue.
    var onEncoded: (@Sendable (Encoded) -> Void)?

    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var fps: Int32
    private var bitrate: Int
    private let tuning: H264Tuning
    private var referenceChain = H264ReferenceChain()
    private var timeline = H264Timeline()

    init(
        fps: Int, bitrate: Int = 2_000_000, tuning: H264Tuning = .lowLatency,
        onEncoded: (@Sendable (Encoded) -> Void)? = nil
    ) {
        self.fps = Int32(fps)
        self.bitrate = bitrate
        self.tuning = tuning
        self.onEncoded = onEncoded
    }

    deinit {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
    }

    func setBitrate(_ bps: Int) throws {
        guard bps > 0 else { throw EncodingFailure(operation: "set bitrate", status: kVTParameterErr) }
        lock.lock()
        defer { lock.unlock() }
        if let session {
            let status = VTSessionSetProperty(
                session, key: kVTCompressionPropertyKey_AverageBitRate,
                value: NSNumber(value: bps))
            guard status == noErr else { throw EncodingFailure(operation: "set bitrate", status: status) }
        }
        bitrate = bps
    }

    /// Retune the live session without resetting its reference chain or timeline.
    func setFrameRate(_ value: Int) throws {
        guard let rate = Int32(exactly: value), rate > 0 else {
            throw EncodingFailure(operation: "set frame rate", status: kVTParameterErr)
        }
        if let session {
            for (key, value) in [
                (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: rate)),
                (
                    kVTCompressionPropertyKey_MaxKeyFrameInterval,
                    NSNumber(value: tuning.maxKeyFrameInterval(fps: Int(rate)))
                ),
            ] {
                let status = VTSessionSetProperty(session, key: key, value: value)
                guard status == noErr else { throw EncodingFailure(operation: "set \(key)", status: status) }
            }
        }
        fps = rate
    }

    /// Submit a surface for encoding. Wraps the IOSurface zero-copy into
    /// a CVPixelBuffer; for the downscaled path use the `CVPixelBuffer`
    /// overload directly.
    func encode(_ surface: IOSurface, forceKeyframe: Bool = false) {
        guard let pixelBuffer = wrap(surface) else { return }
        encode(pixelBuffer, forceKeyframe: forceKeyframe)
    }

    /// Submit a CVPixelBuffer for encoding. Used by the scaled path so the
    /// caller can hand in a smaller buffer directly. Returns immediately;
    /// output fires on VT's queue.
    func encode(_ pixelBuffer: CVPixelBuffer, forceKeyframe: Bool = false) {
        encode(pixelBuffer, forceKeyframe: forceKeyframe, strict: false) { [weak self] result in
            if case .success(let encoded?) = result { self?.onEncoded?(encoded) }
        }
    }

    /// The completion belongs to this exact submission, including failures.
    func encode(
        _ pixelBuffer: CVPixelBuffer, forceKeyframe: Bool = false,
        completion: @escaping @Sendable (Result<Encoded?, any Error>) -> Void
    ) {
        encode(pixelBuffer, forceKeyframe: forceKeyframe, strict: true, completion: completion)
    }

    func stop() {
        lock.withLock { referenceChain.reset() }
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    private func encode(
        _ pixelBuffer: CVPixelBuffer, forceKeyframe: Bool, strict: Bool,
        completion: @escaping @Sendable (Result<Encoded?, any Error>) -> Void
    ) {
        let w = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let h = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if session == nil || w != width || h != height {
            width = w
            height = h
            do { try rebuildSession(strict: strict) } catch {
                completion(.failure(error))
                return
            }
        }
        guard let session else {
            completion(.failure(EncodingFailure(operation: "create session", status: -1)))
            return
        }

        let (generation, needsKeyframe) = lock.withLock { (referenceChain.generation, referenceChain.needsKeyframe) }
        let frameProps: NSDictionary? =
            (forceKeyframe || needsKeyframe)
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as NSDictionary
            : nil

        let pts = timeline.next(fps: fps)

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProps,
            infoFlagsOut: nil
        ) { [weak self] status, flags, sampleBuffer in
            guard let self else { return }
            completion(output(generation: generation, status: status, flags: flags, sampleBuffer: sampleBuffer))
        }
        if status != noErr { completion(.failure(EncodingFailure(operation: "submit frame", status: status))) }
    }

    func output(
        generation: Int, status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?
    ) -> Result<Encoded?, any Error> {
        lock.withLock {
            guard generation == referenceChain.generation else { return .success(nil) }
            guard status == noErr else {
                return .failure(EncodingFailure(operation: "encode frame output", status: status))
            }
            // Real-time VT sessions may complete a submission without emitting a frame.
            guard !flags.contains(.frameDropped), let sampleBuffer else { return .success(nil) }
            guard let encoded = extract(from: sampleBuffer) else {
                return .failure(EncodingFailure(operation: "read encoded frame", status: -1))
            }
            guard
                referenceChain.accepts(
                    generation: generation, keyframe: encoded.kind == .keyframe,
                    hasDescription: encoded.description != nil
                )
            else { return .success(nil) }
            return .success(encoded)
        }
    }

    // MARK: - private

    private func wrap(_ surface: IOSurface) -> CVPixelBuffer? {
        var pb: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surface,
            [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
            &pb
        )
        return status == kCVReturnSuccess ? pb?.takeRetainedValue() : nil
    }

    private func rebuildSession(strict: Bool) throws {
        lock.withLock { referenceChain.reset() }
        if let session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }

        // Low-latency rate control is a create-time spec, not a settable
        // property; everything else below is a post-create property.
        let encoderSpec: CFDictionary? =
            tuning.lowLatencyRateControl
            ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!] as CFDictionary
            : nil

        var sess: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width, height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec,
            imageBufferAttributes: nil,
            compressedDataAllocator: kCFAllocatorDefault,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &sess
        )
        guard status == noErr, let sess else { throw EncodingFailure(operation: "create session", status: status) }

        // Values from `H264Tuning` (unit-tested); mapping to VT keys is the
        // irreducible call. Per-submit completion callers require every
        // requested property; legacy callers retain best-effort tuning.
        var props: [(CFString, Any)] = [
            (kVTCompressionPropertyKey_RealTime, (tuning.realTime ? kCFBooleanTrue : kCFBooleanFalse)!),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel),
            (
                kVTCompressionPropertyKey_AllowFrameReordering,
                (tuning.allowFrameReordering ? kCFBooleanTrue : kCFBooleanFalse)!
            ),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate)),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps)),
            (
                kVTCompressionPropertyKey_MaxKeyFrameInterval,
                NSNumber(value: tuning.maxKeyFrameInterval(fps: Int(fps)))
            ),
        ]
        if let maxDelay = tuning.maxFrameDelayCount {
            props.append((kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: maxDelay)))
        }
        do {
            for (key, value) in props {
                let status = VTSessionSetProperty(sess, key: key, value: value as CFTypeRef)
                if strict, status != noErr { throw EncodingFailure(operation: "set \(key)", status: status) }
            }
            let status = VTCompressionSessionPrepareToEncodeFrames(sess)
            if strict, status != noErr { throw EncodingFailure(operation: "prepare session", status: status) }
        } catch {
            VTCompressionSessionInvalidate(sess)
            throw error
        }

        session = sess
    }

    private struct EncodingFailure: Error, CustomStringConvertible {
        let operation: String
        let status: OSStatus
        var description: String { "H.264 \(operation) failed (\(status))" }
    }

    private func extract(from sample: CMSampleBuffer) -> Encoded? {
        let isKeyframe = !cmSampleNotSync(sample)
        guard let dataBuf = CMSampleBufferGetDataBuffer(sample) else { return nil }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard
            CMBlockBufferGetDataPointer(
                dataBuf, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &totalLength, dataPointerOut: &dataPointer
            ) == noErr, let dataPointer
        else {
            return nil
        }
        let avcc = Data(bytes: dataPointer, count: totalLength)

        var description: Data?
        if isKeyframe, referenceChain.needsKeyframe,
            let format = CMSampleBufferGetFormatDescription(sample)
        {
            description = avcCBlob(from: format)
        }

        return Encoded(
            description: description,
            kind: isKeyframe ? .keyframe : .delta,
            avcc: avcc
        )
    }

    private func cmSampleNotSync(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
            CFArrayGetCount(attachments) > 0,
            let dict = CFArrayGetValueAtIndex(attachments, 0)
        else { return false }
        let cfDict = unsafeBitCast(dict, to: CFDictionary.self)
        return CFDictionaryContainsKey(cfDict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
    }

    /// avcC parameter-set blob (ISO/IEC 14496-15 §5.2.4.1).
    private func avcCBlob(from format: CMFormatDescription) -> Data? {
        var spsCount = 0
        var spsPtr: UnsafePointer<UInt8>?
        var spsSize = 0
        var nalSize: Int32 = 0
        guard
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0,
                parameterSetPointerOut: &spsPtr,
                parameterSetSizeOut: &spsSize,
                parameterSetCountOut: &spsCount,
                nalUnitHeaderLengthOut: &nalSize
            ) == noErr, let spsPtr
        else { return nil }

        var ppsPtr: UnsafePointer<UInt8>?
        var ppsSize = 0
        guard
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPtr,
                parameterSetSizeOut: &ppsSize,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            ) == noErr, let ppsPtr
        else { return nil }

        let sps = UnsafeBufferPointer(start: spsPtr, count: spsSize)
        let pps = UnsafeBufferPointer(start: ppsPtr, count: ppsSize)
        var blob = Data()
        blob.append(0x01)
        blob.append(sps[1])
        blob.append(sps[2])
        blob.append(sps[3])
        blob.append(0xFF)
        blob.append(0xE1)
        blob.append(UInt8((spsSize >> 8) & 0xFF))
        blob.append(UInt8(spsSize & 0xFF))
        blob.append(contentsOf: sps)
        blob.append(0x01)
        blob.append(UInt8((ppsSize >> 8) & 0xFF))
        blob.append(UInt8(ppsSize & 0xFF))
        blob.append(contentsOf: pps)
        return blob
    }
}
