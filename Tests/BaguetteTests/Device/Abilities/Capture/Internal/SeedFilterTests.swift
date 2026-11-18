import IOSurface
import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("SeedFilter")
struct SeedFilterTests {
    @Test func `should pass along distinct rendered frames even when they share a seed`() throws {
        var filter = SeedFilter()
        let first = try #require(Self.surface())
        let second = try #require(Self.surface())

        let emitsFirst = filter.shouldEmit(first)
        let emitsSecond = filter.shouldEmit(second)
        #expect(emitsFirst)
        #expect(emitsSecond)
    }

    private static func surface() -> IOSurface? {
        IOSurfaceCreate([
            kIOSurfaceWidth: 2,
            kIOSurfaceHeight: 2,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: 8,
            kIOSurfaceAllocSize: 16,
            kIOSurfacePixelFormat: UInt32(0x42475241),
        ] as CFDictionary)
    }
}
