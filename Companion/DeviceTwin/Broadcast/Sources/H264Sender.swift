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

    func encode(_ sampleBuffer: CMSampleBuffer, orientation: String) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // ReplayKit can deliver at ProMotion rates; 30 fps is smooth
        // enough for a mirror and halves the encode budget.
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFrameTime >= 1.0 / 30.0 else { return }
        lastFrameTime = now

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if session == nil {
            makeSession(width: width, height: height)
            transport.send(text: TwinWire.format(
                width: width, height: height,
                orientation: orientation, codec: "avcc"
            ))
        }
        guard let session else { return }

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
        VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard let session else {
            NSLog("H264Sender: compression session refused")
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
        var totalLength = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength, dataPointerOut: &pointer
        ) == noErr, let pointer else { return }
        let payload = Data(bytes: pointer, count: totalLength)

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
