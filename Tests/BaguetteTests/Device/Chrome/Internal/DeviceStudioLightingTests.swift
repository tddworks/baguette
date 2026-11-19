import SceneKit
import Testing

@testable import Baguette
@testable import BaguetteDevice

@Suite("DeviceStudioLighting")
struct DeviceStudioLightingTests {
    @Test
    func `should light device finishes at a non-clipping exposure`() {
        let scene = SCNScene()

        DeviceStudioLighting.apply(to: scene)

        // 2.6 clipped Cosmic Orange finishes (R=255) and blew out rail
        // reflections; 1.5 keeps every sampled finish zone below clipping.
        #expect(scene.lightingEnvironment.intensity == 1.5)
        #expect(scene.lightingEnvironment.contents != nil)
    }

    @Test
    func `should expose an engine-neutral equirectangular environment`() {
        let image = DeviceStudioLighting.equirectangularImage

        #expect(image.width == 1024)
        #expect(image.height == 512)
        // 2^1.5 measured closest to Quick Look's rendering of the same
        // device.usdz across glass, plateau, and rail sample zones.
        #expect(DeviceStudioLighting.intensityExponent == 1.5)
    }
}
