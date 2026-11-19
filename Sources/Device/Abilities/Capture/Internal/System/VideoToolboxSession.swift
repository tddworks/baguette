import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// `CompressionSession` on VideoToolbox: each call is one `VTCompressionSession`
/// call, mapped and answered with its status. What to call when is
/// `H264Encoder`'s.
final class VideoToolboxSession: CompressionSession, @unchecked Sendable {
    private var session: VTCompressionSession?

    deinit { close() }

    func open(width: Int32, height: Int32, lowLatencyRateControl: Bool) -> Int32 {
        close()
        let spec: CFDictionary? = lowLatencyRateControl
            ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!] as CFDictionary
            : nil
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: width, height: height,
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
            imageBufferAttributes: nil, compressedDataAllocator: kCFAllocatorDefault,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        session = status == noErr ? created : nil
        return status == noErr && created == nil ? -1 : status
    }

    func set(_ property: CompressionProperty) -> Int32 {
        guard let session else { return kVTInvalidSessionErr }
        let (key, value) = Self.entry(property)
        return VTSessionSetProperty(session, key: key, value: value)
    }

    func prepare() -> Int32 {
        guard let session else { return kVTInvalidSessionErr }
        return VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func submit(
        _ frame: CVPixelBuffer, at time: CMTime, keyframe: Bool,
        done: @escaping @Sendable (CompressionResult) -> Void
    ) -> Int32 {
        guard let session else { return kVTInvalidSessionErr }
        let options = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as NSDictionary : nil
        return VTCompressionSessionEncodeFrame(
            session, imageBuffer: frame, presentationTimeStamp: time, duration: .invalid,
            frameProperties: options, infoFlagsOut: nil
        ) { status, flags, sample in
            done(CompressionResult(
                status: status, dropped: flags.contains(.frameDropped),
                frame: sample.flatMap(CompressedFrame.reading)))
        }
    }

    func close() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    private static func entry(_ property: CompressionProperty) -> (CFString, CFTypeRef) {
        switch property {
        case .realTime(let on): (kVTCompressionPropertyKey_RealTime, on ? kCFBooleanTrue : kCFBooleanFalse)
        case .highProfileAutoLevel: (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        case .allowFrameReordering(let on):
            (kVTCompressionPropertyKey_AllowFrameReordering, on ? kCFBooleanTrue : kCFBooleanFalse)
        case .averageBitRate(let bps): (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bps))
        case .expectedFrameRate(let fps): (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        case .maxKeyFrameInterval(let n): (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: n))
        case .maxFrameDelayCount(let n): (kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: n))
        }
    }
}
