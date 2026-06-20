import Foundation

/// One BGRA frame about to be written into the shared-memory buffer.
/// Construction validates size — the dylib's reader trusts the header
/// and treats `width * height * 4` pixels verbatim, so a mismatch
/// here would either tear or read past the buffer.
struct CameraFrame: Sendable {
    let sequence: UInt32
    let timestampMs: UInt32
    let width: UInt32
    let height: UInt32
    let pixels: Data

    var expectedPixelByteCount: Int { Int(width) * Int(height) * 4 }

    init(
        sequence: UInt32,
        timestampMs: UInt32,
        width: UInt32,
        height: UInt32,
        pixels: Data
    ) throws {
        guard width > 0, height > 0 else {
            throw CameraFrameError.invalidDimensions(width: width, height: height)
        }
        guard
            Int(width)  <= SharedFrameLayout.maxCanvasWidth,
            Int(height) <= SharedFrameLayout.maxCanvasHeight
        else {
            throw CameraFrameError.frameTooLarge(width: width, height: height)
        }
        let expected = Int(width) * Int(height) * 4
        guard pixels.count == expected else {
            throw CameraFrameError.pixelDataSizeMismatch(expected: expected, got: pixels.count)
        }
        self.sequence = sequence
        self.timestampMs = timestampMs
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

enum CameraFrameError: Error, Equatable {
    case invalidDimensions(width: UInt32, height: UInt32)
    case frameTooLarge(width: UInt32, height: UInt32)
    case pixelDataSizeMismatch(expected: Int, got: Int)
}
