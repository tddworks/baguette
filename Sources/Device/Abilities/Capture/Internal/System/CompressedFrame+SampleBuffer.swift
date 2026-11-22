import CoreMedia
import Foundation

extension CompressedFrame {
    /// Read one compressed frame out of the sample VideoToolbox hands back:
    /// its bytes, whether it is a keyframe, and on a keyframe its SPS and PPS.
    static func reading(_ sample: CMSampleBuffer) -> CompressedFrame? {
        guard let buffer = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            buffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer
        ) == noErr, let pointer else { return nil }

        let keyframe = !notSync(sample)
        let format = keyframe ? CMSampleBufferGetFormatDescription(sample) : nil
        return CompressedFrame(
            avcc: Data(bytes: pointer, count: length), keyframe: keyframe,
            records: format.map(records) ?? [:])
    }

    /// The decoder configuration records the format carries, as VideoToolbox made them.
    private static func records(of format: CMFormatDescription) -> [String: Data] {
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any]
        return extensions?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Data] ?? [:]
    }

    private static func notSync(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
            CFArrayGetCount(attachments) > 0,
            let first = CFArrayGetValueAtIndex(attachments, 0)
        else { return false }
        let dictionary = unsafeBitCast(first, to: CFDictionary.self)
        return CFDictionaryContainsKey(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
    }

}

/// A pixel buffer over a surface, without copying it.
enum PixelBuffer {
    static func wrapping(_ surface: IOSurface) -> CVPixelBuffer? {
        var buffer: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surface,
            [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary, &buffer)
        return status == kCVReturnSuccess ? buffer?.takeRetainedValue() : nil
    }
}
