import CoreMedia
import CoreVideo
import Foundation
import TwinWire
import VideoToolbox

/// Screen pixel buffers in, twin-envelope chunks out. Rules imposed by
/// the broadcast extension's ~50 MB ceiling: encode immediately with
/// the hardware encoder, hand the chunk to the transport's
/// latest-frame-drop path, never buffer frames here.
final class H264Sender {
    private let transport: TwinTransport
    private var session: VTCompressionSession?
    private var lastFrameTime: CFAbsoluteTime = 0
    private var sentDescription = false
    private var frameIndex: Int64 = 0

    init(transport: TwinTransport) {
        self.transport = transport
    }

    /// Returns `false` when a hardware encoder session cannot be
    /// created, so the caller can end the broadcast with a real error
    /// instead of streaming nothing. A software H.264 encoder is never
    /// an acceptable substitute: its first frame blows the extension's
    /// CPU budget and iOS kills the broadcast anyway.
    func encode(_ sampleBuffer: CMSampleBuffer, orientation: String) -> Bool {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return true }
        // ReplayKit can deliver at ProMotion rates; 30 fps is smooth
        // enough for a mirror and halves the encode budget.
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFrameTime >= 1.0 / 30.0 else { return true }
        lastFrameTime = now

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if session == nil {
            makeSession(width: width, height: height)
            guard session != nil else { return false }
            transport.send(text: TwinWire.format(
                width: width, height: height,
                orientation: orientation, codec: "avcc"
            ))
        }
        guard let session else { return false }

        frameIndex += 1
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: timestamp,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, _, encoded in
            guard status == noErr, let encoded else { return }
            self?.ship(encoded)
        }
        return true
    }

    func finish() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        sentDescription = false
    }

    private func makeSession(width: Int, height: Int) {
        var session: VTCompressionSession?
        let hardwareOnly: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: hardwareOnly as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            NSLog("H264Sender: hardware compression session refused (status %d)", status)
            return
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_Main_AutoLevel
        )
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: 60 as CFNumber
        )
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_AverageBitRate,
            value: 4_000_000 as CFNumber
        )
        self.session = session
        self.sentDescription = false
    }

    private func ship(_ sampleBuffer: CMSampleBuffer) {
        // The avcC parameter sets ride a description chunk before the
        // first frame (and again if the encoder ever rebuilds them).
        if !sentDescription,
           let description = CMSampleBufferGetFormatDescription(sampleBuffer),
           let atoms = CMFormatDescriptionGetExtension(
               description,
               extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
           ) as? [String: Any],
           let avcC = atoms["avcC"] as? Data {
            transport.send(chunk: TwinWire.chunk(tag: TwinWire.descriptionTag, payload: avcC))
            sentDescription = true
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        // Copy, never alias: hardware encoders emit NON-contiguous
        // block buffers, and `CMBlockBufferGetDataPointer` only maps
        // the first contiguous range — reading `totalLength` bytes
        // from it walks off the mapping and kills the extension on
        // the very first frame (macOS happens to hand back contiguous
        // buffers, which is why this survives a Mac harness).
        let totalLength = CMBlockBufferGetDataLength(dataBuffer)
        var payload = Data(count: totalLength)
        let copied = payload.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                dataBuffer, atOffset: 0, dataLength: totalLength, destination: base
            )
        }
        guard copied == noErr else {
            NSLog("H264Sender: frame copy failed (status %d)", copied)
            return
        }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        transport.send(chunk: TwinWire.chunk(
            tag: notSync ? TwinWire.deltaTag : TwinWire.keyframeTag,
            payload: payload
        ))
    }
}
