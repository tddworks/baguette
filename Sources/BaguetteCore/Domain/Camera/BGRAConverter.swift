import Foundation

/// Pure factory: turns a `CVPixelBuffer`'s row-strided BGRA bytes
/// into a tightly-packed `CameraFrame`. `CVPixelBuffer` typically
/// pads each row up to a hardware-friendly alignment (64 or 16
/// bytes); the shared-buffer reader assumes `width * height * 4` of
/// contiguous pixels, so we strip the padding here.
///
/// All inputs are raw values — no CoreMedia types — so the
/// conversion is unit-tested without a real `CMSampleBuffer`. The
/// Infrastructure layer does the
/// `CMSampleBufferGetImageBuffer` → `CVPixelBufferLockBaseAddress`
/// dance and hands us the locked base address.
enum BGRAConverter {

    /// Build a `CameraFrame` by copying `width * 4` bytes per row out
    /// of the strided source. Fast path when `bytesPerRow == width * 4`
    /// (no padding) avoids the per-row memcpy.
    static func convert(
        baseAddress: UnsafeRawPointer,
        width: UInt32,
        height: UInt32,
        bytesPerRow: Int,
        sequence: UInt32,
        timestampMs: UInt32
    ) throws -> CameraFrame {
        let rowBytes = Int(width) * 4
        let packedSize = rowBytes * Int(height)

        let packed: Data
        if bytesPerRow == rowBytes {
            packed = Data(bytes: baseAddress, count: packedSize)
        } else {
            var out = Data(count: packedSize)
            out.withUnsafeMutableBytes { outPtr in
                guard let dst = outPtr.baseAddress else { return }
                for row in 0..<Int(height) {
                    memcpy(
                        dst.advanced(by: row * rowBytes),
                        baseAddress.advanced(by: row * bytesPerRow),
                        rowBytes
                    )
                }
            }
            packed = out
        }

        return try CameraFrame(
            sequence: sequence,
            timestampMs: timestampMs,
            width: width,
            height: height,
            pixels: packed
        )
    }
}
