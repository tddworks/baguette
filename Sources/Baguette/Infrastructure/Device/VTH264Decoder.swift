import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import VideoToolbox

/// The irreducible VideoToolbox calls behind `H264Decoder` —
/// integration-only, like `HostSubprocess`. Everything decidable
/// without a GPU (avcC parsing, chunk classification, fan-out) lives
/// in `AVCCParameterSets` and `TwinScreen` and is unit-covered.
final class VTH264Decoder: H264Decoder, @unchecked Sendable {
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var onFrame: (@Sendable (IOSurface) -> Void)?

    func configure(description: Data, onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        guard let sets = AVCCParameterSets.parse(avcC: description) else {
            throw DecoderError.malformedDescription
        }
        let format = try sets.sps[0].withUnsafeBytes { sps in
            try sets.pps[0].withUnsafeBytes { pps in
                var description: CMVideoFormatDescription?
                let pointers: [UnsafePointer<UInt8>] = [
                    sps.bindMemory(to: UInt8.self).baseAddress!,
                    pps.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [sets.sps[0].count, sets.pps[0].count]
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: Int32(sets.naluHeaderLength),
                    formatDescriptionOut: &description
                )
                guard status == noErr, let description else {
                    throw DecoderError.formatRejected(status)
                }
                return description
            }
        }

        var session: VTDecompressionSession?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw DecoderError.sessionRejected(status)
        }

        lock.lock()
        if let old = self.session { VTDecompressionSessionInvalidate(old) }
        self.session = session
        self.format = format
        self.onFrame = onFrame
        lock.unlock()
        log("[device] decoder configured (\(sets.naluHeaderLength)-byte NALU prefixes)")
    }

    func decode(_ frame: Data) {
        lock.lock()
        guard let session, let format else {
            lock.unlock()
            return
        }
        let deliver = onFrame
        lock.unlock()

        var blockBuffer: CMBlockBuffer?
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: frame.count, alignment: 1)
        frame.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: frame.count)
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: bytes,
            blockLength: frame.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frame.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else {
            bytes.deallocate()
            return
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = frame.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            guard status == noErr,
                  let imageBuffer,
                  let surface = CVPixelBufferGetIOSurface(imageBuffer)?.takeUnretainedValue() else {
                return
            }
            deliver?(unsafeDowncast(surface, to: IOSurface.self))
        }
    }

    func stop() {
        lock.lock()
        let session = self.session
        self.session = nil
        self.format = nil
        self.onFrame = nil
        lock.unlock()
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    enum DecoderError: Error {
        case malformedDescription
        case formatRejected(OSStatus)
        case sessionRejected(OSStatus)
    }
}
