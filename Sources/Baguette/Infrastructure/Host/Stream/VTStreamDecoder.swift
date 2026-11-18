import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import VideoToolbox

/// The VideoToolbox calls behind `StreamDecoder` — integration-only. A
/// phone's screen stream (H.264) and anything else that hands over raw
/// parameter sets decode here; BGRA, IOSurface-backed, like every Screen.
/// Told the screen's size, it crops each picture to it (the picture's
/// top-left, by a clean aperture VideoToolbox applies as it converts), so
/// frames are the screen and never the stream's padding.
final class VTStreamDecoder: StreamDecoder, @unchecked Sendable {
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var onFrame: (@Sendable (IOSurface) -> Void)?
    private var reportedDecodeFailure = false
    /// The last few decoded frames, kept alive. VideoToolbox reuses a
    /// frame's IOSurface as soon as its pixel buffer is released; the stream
    /// pipeline reads the newest surface a moment later, on its own tick.
    private var recent: [CVPixelBuffer] = []
    private static let heldFrames = 6

    func configure(parameterSets: [Data], screen: Size?, onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        var format = try Self.format(parameterSets: parameterSets)
        let coded = CMVideoFormatDescriptionGetDimensions(format)
        let aperture = screen.flatMap {
            CleanAperture(screen: $0, picture: Size(width: Double(coded.width), height: Double(coded.height)))
        }
        var attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        if let aperture {
            format = try Self.format(format, croppedTo: aperture)
            attributes[kCVPixelBufferWidthKey] = Int(aperture.width)
            attributes[kCVPixelBufferHeightKey] = Int(aperture.height)
        }
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &session)
        guard status == noErr, let session else { throw DecoderError.sessionRejected(status) }
        if aperture != nil {
            VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_PixelTransferProperties, value: [
                kVTPixelTransferPropertyKey_ScalingMode: kVTScalingMode_CropSourceToCleanAperture,
            ] as CFDictionary)
        }

        let old: VTDecompressionSession? = lock.withLock {
            defer { self.session = session; self.format = format; self.onFrame = onFrame; recent = [] }
            return self.session
        }
        if let old { VTDecompressionSessionInvalidate(old) }
        log("[video] decoder configured: h264 \(coded.width)×\(coded.height)"
            + (aperture.map { ", cropped to \(Int($0.width))×\(Int($0.height))" } ?? ""))
    }

    /// Decodes synchronously, one frame after another in arrival order.
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
            session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            guard status == noErr, let imageBuffer,
                  let surface = CVPixelBufferGetIOSurface(imageBuffer)?.takeUnretainedValue() else {
                // Once: a failure at 60 fps must not flood the log.
                if !self.reportedDecodeFailure {
                    self.reportedDecodeFailure = true
                    log("[video] decode failed: status=\(status)")
                }
                return
            }
            self.hold(imageBuffer)
            deliver?(unsafeDowncast(surface, to: IOSurface.self))
        }
    }

    private func hold(_ buffer: CVPixelBuffer) {
        lock.withLock {
            recent.append(buffer)
            if recent.count > Self.heldFrames { recent.removeFirst(recent.count - Self.heldFrames) }
        }
    }

    func stop() {
        let session: VTDecompressionSession? = lock.withLock {
            defer { self.session = nil; format = nil; onFrame = nil; recent = [] }
            return self.session
        }
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    private static func format(parameterSets: [Data]) throws -> CMVideoFormatDescription {
        let buffers = parameterSets.map { [UInt8]($0) }
        var description: CMVideoFormatDescription?
        let status: OSStatus = withPointers(to: buffers) { pointers in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: buffers.map(\.count),
                nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        }
        guard status == noErr, let description else { throw DecoderError.formatRejected(status) }
        return description
    }

    /// The same format, carrying the clean aperture the session crops to.
    private static func format(_ format: CMVideoFormatDescription, croppedTo aperture: CleanAperture) throws -> CMVideoFormatDescription {
        var extensions = (CMFormatDescriptionGetExtensions(format) as? [CFString: Any]) ?? [:]
        extensions[kCMFormatDescriptionExtension_CleanAperture] = [
            kCMFormatDescriptionKey_CleanApertureWidth: aperture.width,
            kCMFormatDescriptionKey_CleanApertureHeight: aperture.height,
            kCMFormatDescriptionKey_CleanApertureHorizontalOffset: aperture.horizontalOffset,
            kCMFormatDescriptionKey_CleanApertureVerticalOffset: aperture.verticalOffset,
        ] as CFDictionary
        let coded = CMVideoFormatDescriptionGetDimensions(format)
        var cropped: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: CMFormatDescriptionGetMediaSubType(format),
            width: coded.width, height: coded.height, extensions: extensions as CFDictionary,
            formatDescriptionOut: &cropped)
        guard status == noErr, let cropped else { throw DecoderError.formatRejected(status) }
        return cropped
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
