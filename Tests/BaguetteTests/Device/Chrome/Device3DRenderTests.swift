import Foundation
import Mockable
import Testing
@testable import BaguetteDevice

/// A device on its 3D model, as it stands now: what its screen shows, on a
/// foldable posed at its hinge's angle, the picture on the panel it lights.
/// The models and the renderer are the caller's, handed in.
@Suite("Device on its 3D model")
struct Device3DRenderTests {
    private static let fold = DeviceModelFold(
        clip: "fold", shutTime: 5, coverMaterial: "Cover",
        coverTextureSize: RenderDimensions(width: 100, height: 200), openPoseDegrees: 130)
    private static let options = DeviceRenderOptions(
        rotation: .zero, variants: [:], size: RenderDimensions(width: 300, height: 400),
        fit: .cover, background: .transparent, screenGlass: false)

    private func device(model: String, hinge: (any Hinge)? = nil) -> MockDevice {
        let device = MockDevice()
        var abilities = Abilities(device: model)
        if let hinge { abilities.register(.hinge) { hinge } }
        given(device).name.willReturn(model)
        given(device).kind.willReturn(DeviceKind(platform: .iOS, reality: .simulated, model: model))
        given(device).state.willReturn(.ready)
        given(device).abilities.willReturn(abilities)
        return device
    }

    private func models(_ installed: InstalledDeviceModel?) -> MockDeviceModels {
        let models = MockDeviceModels()
        given(models).match(deviceType: .any, deviceName: .any).willReturn(installed)
        return models
    }

    private func renderer() -> MockDeviceRenderer {
        let renderer = MockDeviceRenderer()
        given(renderer).render(plan: .any, screenImage: .any).willReturn(Data("PNG".utf8))
        return renderer
    }

    @Test func `should pose a foldable at its hinge's angle with its picture on the panel it lights`() throws {
        let hinge = MockHinge()
        given(hinge).angle().willReturn(HingeAngle(degrees: 100))
        given(hinge).presentingPanel().willReturn(.primary)
        let renderer = renderer()

        let render = try device(model: "iPhone Duo", hinge: hinge).render3D(
            screenImage: Data("SCREEN".utf8), sourceSize: RenderDimensions(width: 100, height: 200),
            models: models(DeviceRenderPlanTests.installed(fold: Self.fold)), renderer: renderer,
            options: Self.options)

        #expect(render.png == Data("PNG".utf8))
        #expect(render.hingeDegrees == 100)
        #expect(render.litPanel == .primary)
        verify(renderer).render(
            plan: .matching { $0.hingeDegrees == 100 && $0.screenPanel == .primary },
            screenImage: .value(Data("SCREEN".utf8))
        ).called(1)
    }

    @Test func `should render a phone as it stands, with no hinge to ask`() throws {
        let renderer = renderer()

        let render = try device(model: "iPhone 17").render3D(
            screenImage: Data("SCREEN".utf8), sourceSize: RenderDimensions(width: 100, height: 200),
            models: models(DeviceRenderPlanTests.installed()), renderer: renderer,
            options: Self.options)

        #expect(render.hingeDegrees == nil)
        #expect(render.litPanel == nil)
        verify(renderer).render(plan: .matching { $0.hingeDegrees == nil }, screenImage: .any).called(1)
    }

    @Test func `should refuse a device no 3D model is installed for`() {
        #expect(throws: DeviceModelError.noModelForDevice("Apple TV")) {
            try device(model: "Apple TV").render3D(
                screenImage: Data(), sourceSize: RenderDimensions(width: 1, height: 1),
                models: models(nil), renderer: renderer(), options: Self.options)
        }
    }
}
