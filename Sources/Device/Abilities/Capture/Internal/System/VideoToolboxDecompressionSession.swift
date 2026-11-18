import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// `DecompressionSession` on VideoToolbox: each call is one
/// `VTDecompressionSession` call, answered with its status. What to open,
/// crop and decode is the decoder's.
final class VideoToolboxDecompressionSession: DecompressionSession, @unchecked Sendable {
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?

    deinit { close() }

    func picture(parameterSets: [Data], nalUnitHeaderLength: Int) -> Result<Size, DecompressionRefusal> {
        CMVideoFormatDescription.h264(parameterSets: parameterSets, nalUnitHeaderLength: nalUnitHeaderLength).map {
            let coded = CMVideoFormatDescriptionGetDimensions($0)
            return Size(width: Double(coded.width), height: Double(coded.height))
        }
    }

    func open(parameterSets: [Data], nalUnitHeaderLength: Int, croppedTo aperture: CleanAperture?) -> DecompressionRefusal? {
        var format: CMVideoFormatDescription
        switch CMVideoFormatDescription.h264(parameterSets: parameterSets, nalUnitHeaderLength: nalUnitHeaderLength) {
        case .success(let described): format = described
        case .failure(let refusal): return refusal
        }
        var attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        if let aperture {
            switch format.cropped(to: aperture) {
            case .success(let cropped): format = cropped
            case .failure(let refusal): return refusal
            }
            attributes[kCVPixelBufferWidthKey] = Int(aperture.width)
            attributes[kCVPixelBufferHeightKey] = Int(aperture.height)
        }
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &created)
        guard status == noErr, let created else { return .session(status) }
        if aperture != nil {
            VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_PixelTransferProperties, value: [
                kVTPixelTransferPropertyKey_ScalingMode: kVTScalingMode_CropSourceToCleanAperture,
            ] as CFDictionary)
        }
        let old = lock.withLock {
            defer { session = created; self.format = format }
            return session
        }
        if let old { VTDecompressionSessionInvalidate(old) }
        return nil
    }

    func decode(_ frame: Data, asynchronously: Bool, done: @escaping @Sendable (DecompressionResult) -> Void) {
        let (session, format) = lock.withLock { (session, format) }
        guard let session, let format, let sample = CMSampleBuffer.holding(frame, as: format) else { return }
        VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: asynchronously ? [._EnableAsynchronousDecompression] : [],
            infoFlagsOut: nil
        ) { status, _, picture, _, _ in
            done(DecompressionResult(status: status, picture: picture))
        }
    }

    func close() {
        let session = lock.withLock {
            defer { session = nil; format = nil }
            return session
        }
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }
}
