import Testing
import Foundation
@testable import BaguetteCore

@Suite("CameraFrame")
struct CameraFrameTests {
    @Test func `accepts a well-formed BGRA frame`() throws {
        let pixels = Data(count: 4 * 4 * 4)  // 4×4 BGRA
        let frame = try CameraFrame(
            sequence: 1, timestampMs: 0, width: 4, height: 4, pixels: pixels
        )
        #expect(frame.expectedPixelByteCount == 4 * 4 * 4)
        #expect(frame.pixels == pixels)
    }

    @Test func `rejects pixel data with wrong length`() {
        #expect(throws: CameraFrameError.pixelDataSizeMismatch(expected: 64, got: 8)) {
            _ = try CameraFrame(
                sequence: 1, timestampMs: 0, width: 4, height: 4, pixels: Data(count: 8)
            )
        }
    }

    @Test func `rejects frames larger than the shared canvas`() {
        // 1281 × 1280 × 4 — one pixel wider than the canvas cap.
        let oversize = 1281 * 1280 * 4
        #expect(throws: CameraFrameError.frameTooLarge(width: 1281, height: 1280)) {
            _ = try CameraFrame(
                sequence: 1, timestampMs: 0, width: 1281, height: 1280, pixels: Data(count: oversize)
            )
        }
    }

    @Test func `rejects zero dimensions`() {
        #expect(throws: CameraFrameError.invalidDimensions(width: 0, height: 4)) {
            _ = try CameraFrame(
                sequence: 1, timestampMs: 0, width: 0, height: 4, pixels: Data()
            )
        }
    }
}
