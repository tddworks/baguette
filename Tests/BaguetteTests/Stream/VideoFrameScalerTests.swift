import CoreVideo
import IOSurface
import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("VideoFrameScaler")
struct VideoFrameScalerTests {
    @Test func `should publish the copied frame before the encoder reads it`() throws {
        let source = try #require(Self.surface())
        let frame = try #require(VideoFrameScaler().scale(source, by: 1))
        let output = try #require(CVPixelBufferGetIOSurface(frame)?.takeUnretainedValue())
        var seed: UInt32 = 0

        IOSurfaceLock(output, .readOnly, &seed)
        IOSurfaceUnlock(output, .readOnly, nil)

        #expect(seed > 1)
    }

    @Test func `should keep scaled frames at even dimensions for 4 2 0 video`() throws {
        let source = try #require(Self.surface(width: 670, height: 1048))
        let frame = try #require(VideoFrameScaler().scale(source, by: 2))

        #expect(CVPixelBufferGetWidth(frame) == 336)
        #expect(CVPixelBufferGetHeight(frame) == 524)
    }

    private static func surface(width: Int = 8, height: Int = 8) -> IOSurface? {
        let bytesPerRow = width * 4
        let allocationSize = bytesPerRow * height
        guard let surface = IOSurfaceCreate([
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: bytesPerRow,
            kIOSurfaceAllocSize: allocationSize,
            kIOSurfacePixelFormat: UInt32(0x42475241),
        ] as CFDictionary) else { return nil }
        IOSurfaceLock(surface, [], nil)
        memset(IOSurfaceGetBaseAddress(surface), 0x7f, allocationSize)
        IOSurfaceUnlock(surface, [], nil)
        return surface
    }
}
