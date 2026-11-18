import CoreMedia
import Foundation

extension CMVideoFormatDescription {
    /// The H.264 format these parameter sets (SPS, then PPS) describe.
    static func h264(parameterSets: [Data], nalUnitHeaderLength: Int) -> Result<CMVideoFormatDescription, DecompressionRefusal> {
        let buffers = parameterSets.map { [UInt8]($0) }
        var description: CMVideoFormatDescription?
        let status: OSStatus = withPointers(to: buffers) { pointers in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: buffers.map(\.count),
                nalUnitHeaderLength: Int32(nalUnitHeaderLength), formatDescriptionOut: &description)
        }
        guard status == noErr, let description else { return .failure(.format(status)) }
        return .success(description)
    }

    /// The same format, carrying the clean aperture a session crops to.
    func cropped(to aperture: CleanAperture) -> Result<CMVideoFormatDescription, DecompressionRefusal> {
        var extensions = (CMFormatDescriptionGetExtensions(self) as? [CFString: Any]) ?? [:]
        extensions[kCMFormatDescriptionExtension_CleanAperture] = [
            kCMFormatDescriptionKey_CleanApertureWidth: aperture.width,
            kCMFormatDescriptionKey_CleanApertureHeight: aperture.height,
            kCMFormatDescriptionKey_CleanApertureHorizontalOffset: aperture.horizontalOffset,
            kCMFormatDescriptionKey_CleanApertureVerticalOffset: aperture.verticalOffset,
        ] as CFDictionary
        let coded = CMVideoFormatDescriptionGetDimensions(self)
        var cropped: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: CMFormatDescriptionGetMediaSubType(self),
            width: coded.width, height: coded.height, extensions: extensions as CFDictionary,
            formatDescriptionOut: &cropped)
        guard status == noErr, let cropped else { return .failure(.format(status)) }
        return .success(cropped)
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
}

extension CMSampleBuffer {
    /// One sample over a copy of `frame`'s bytes, in `format`.
    static func holding(_ frame: Data, as format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: frame.count, alignment: 1)
        frame.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: frame.count)
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: bytes, blockLength: frame.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: frame.count, flags: 0, blockBufferOut: &block
        ) == noErr, let block else {
            bytes.deallocate()
            return nil
        }
        var sample: CMSampleBuffer?
        var size = frame.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }
}
