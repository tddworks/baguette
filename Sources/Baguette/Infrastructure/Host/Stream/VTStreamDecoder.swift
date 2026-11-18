import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import VideoToolbox

/// The VideoToolbox calls behind `StreamDecoder` — integration-only. A
/// phone's screen stream (HEVC) and anything else that hands over raw
/// parameter sets decode here; BGRA, IOSurface-backed, like every Screen.
final class VTStreamDecoder: StreamDecoder, @unchecked Sendable {
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var onFrame: (@Sendable (IOSurface) -> Void)?
    private var reportedDecodeFailure = false

    func configure(codec: VideoCodec, parameterSets: [Data], onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        let format = try Self.format(codec: codec, parameterSets: parameterSets)
        var session: VTDecompressionSession?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &session)
        guard status == noErr, let session else { throw DecoderError.sessionRejected(status) }

        let old: VTDecompressionSession? = lock.withLock {
            defer { self.session = session; self.format = format; self.onFrame = onFrame }
            return self.session
        }
        if let old { VTDecompressionSessionInvalidate(old) }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        log("[video] decoder configured: \(codec) \(dimensions.width)×\(dimensions.height)")
    }

    func decode(_ frame: Data) {
        let (session, format, deliver) = lock.withLock { (self.session, self.format, self.onFrame) }
        guard let session, let format, !frame.isEmpty else { return }

        var blockBuffer: CMBlockBuffer?
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: frame.count, alignment: 1)
        frame.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: frame.count)
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: bytes, blockLength: frame.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: frame.count, flags: 0, blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else {
            bytes.deallocate()
            return
        }
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = frame.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer,
                  let surface = CVPixelBufferGetIOSurface(imageBuffer)?.takeUnretainedValue() else {
                // Once: a failure at 60 fps must not flood the log.
                if let self, !self.reportedDecodeFailure {
                    self.reportedDecodeFailure = true
                    log("[video] decode failed: status=\(status)")
                }
                return
            }
            deliver?(unsafeDowncast(surface, to: IOSurface.self))
        }
    }

    func stop() {
        let session: VTDecompressionSession? = lock.withLock {
            defer { self.session = nil; format = nil; onFrame = nil }
            return self.session
        }
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    private static func format(codec: VideoCodec, parameterSets: [Data]) throws -> CMVideoFormatDescription {
        let buffers = parameterSets.map { [UInt8]($0) }
        var description: CMVideoFormatDescription?
        let status: OSStatus = withPointers(to: buffers) { pointers in
            switch codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                    parameterSetPointers: pointers, parameterSetSizes: buffers.map(\.count),
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                    parameterSetPointers: pointers, parameterSetSizes: buffers.map(\.count),
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { throw DecoderError.formatRejected(status) }
        return description
    }

    /// Stable pointers to each buffer, for the length of `body`.
    private static func withPointers<R>(to buffers: [[UInt8]], _ body: ([UnsafePointer<UInt8>]) -> R) -> R {
        let copies = buffers.map { buffer -> UnsafeMutablePointer<UInt8> in
            let copy = UnsafeMutablePointer<UInt8>.allocate(capacity: max(buffer.count, 1))
            copy.initialize(from: buffer, count: buffer.count)
            return copy
        }
        defer { copies.forEach { $0.deallocate() } }
        return body(copies.map { UnsafePointer($0) })
    }

    enum DecoderError: Error {
        case formatRejected(OSStatus)
        case sessionRejected(OSStatus)
    }
}
