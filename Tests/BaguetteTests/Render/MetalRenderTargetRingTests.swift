import IOSurface
import Metal
import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("MetalRenderTargetRing")
struct MetalRenderTargetRingTests {
    @Test func `should provide single-sample render targets the engine antialiases into`() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let ring = try MetalRenderTargetRing(
            width: 320,
            height: 240,
            device: device
        )

        let target = ring.next()

        #expect(target.texture.sampleCount == 1)
        #expect(target.texture.usage.contains(.renderTarget))
        #expect(IOSurfaceGetWidth(target.surface) == 320)
        #expect(IOSurfaceGetHeight(target.surface) == 240)
    }

    @Test func `should cycle through three stable codec surfaces`() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let ring = try MetalRenderTargetRing(
            width: 320,
            height: 240,
            device: device
        )

        let ids = (0..<6).map { _ in IOSurfaceGetID(ring.next().surface) }

        #expect(Set(ids.prefix(3)).count == 3)
        #expect(ids[3] == ids[0])
        #expect(ids[4] == ids[1])
        #expect(ids[5] == ids[2])
    }
}
