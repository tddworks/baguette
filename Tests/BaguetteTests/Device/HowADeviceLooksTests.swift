import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// How a device looks: its chrome found by its model, and — on a
/// foldable — the panel its hinge lights.
@Suite("How a device looks")
struct HowADeviceLooksTests {

    private func device(model: String, hinge: (any Hinge)? = nil) -> MockDevice {
        var abilities = Abilities(device: model)
        if let hinge { abilities.register(.hinge) { hinge } }
        let device = MockDevice()
        given(device).name.willReturn(model)
        given(device).state.willReturn(.ready)
        given(device).kind.willReturn(DeviceKind(platform: .iOS, reality: .simulated, model: model))
        given(device).abilities.willReturn(abilities)
        return device
    }

    private func duo(angle: HingeAngle?) -> (MockDevice, MockChromes) {
        let hinge = MockHinge()
        given(hinge).angle().willReturn(angle)
        given(hinge).presentingPanel().willReturn(nil)
        let chromes = MockChromes()
        given(chromes).panels(forDeviceName: .value("iPhone Duo")).willReturn([.primary, .secondary])
        return (device(model: "iPhone Duo", hinge: hinge), chromes)
    }

    @Test func `should light a foldable's cover when it is folded`() {
        let (duo, chromes) = duo(angle: HingeAngle(degrees: 3))
        #expect(duo.litPanel(in: chromes) == .primary)
    }

    @Test func `should light a foldable's unfolded panel when it is open`() {
        let (duo, chromes) = duo(angle: HingeAngle(degrees: 130))
        #expect(duo.litPanel(in: chromes) == .secondary)
    }

    @Test func `should light the cover when the hinge gives no reading`() {
        let (duo, chromes) = duo(angle: nil)
        #expect(duo.litPanel(in: chromes) == .primary)
    }

    @Test func `should never ask the hinge of a device with one panel`() {
        let chromes = MockChromes()
        given(chromes).panels(forDeviceName: .any).willReturn([.primary])
        #expect(device(model: "iPhone 17 Pro").litPanel(in: chromes) == .primary)
    }

    @Test func `should find a device's chrome by its model, the lit panel's on a foldable`() {
        let (duo, chromes) = duo(angle: HingeAngle(degrees: 130))
        let unfolded = DeviceChromeAssets(
            chrome: DeviceChrome(
                identifier: "phone14",
                screenInsets: Insets(top: 0, left: 0, bottom: 0, right: 0),
                outerCornerRadius: 0, buttons: [],
                compositeImageName: "X"
            ),
            composite: ChromeImage(data: Data(), size: Size(width: 1, height: 1))
        )
        given(chromes).assets(forDeviceName: .value("iPhone Duo"), panel: .value(.secondary)).willReturn(unfolded)

        #expect(duo.chrome(in: chromes)?.chrome.identifier == "phone14")
    }

    // MARK: - its 3D model

    @Test func `should find a phone's 3D model by its hardware id first`() throws {
        let models = MockDeviceModels()
        given(models).match(hardware: .value("iPhone19,7")).willReturn(nil)
        given(models).match(deviceType: .any, deviceName: .any).willReturn(nil)
        let phone = MockDevice()
        given(phone).name.willReturn("han's iPhone")
        given(phone).kind.willReturn(DeviceKind(platform: .iOS, reality: .physical, model: "iPhone 18 Pro Max", hardware: "iPhone19,7"))

        _ = try phone.model3D(in: models)

        verify(models).match(hardware: .value("iPhone19,7")).called(1)
    }

    @Test func `should find a simulator's 3D model by its model, then by its name`() throws {
        let models = MockDeviceModels()
        given(models).match(deviceType: .any, deviceName: .any).willReturn(nil)
        let sim = MockDevice()
        given(sim).name.willReturn("my clone")
        given(sim).kind.willReturn(DeviceKind(platform: .iOS, reality: .simulated, model: "iPhone 17 Pro"))

        _ = try sim.model3D(in: models)

        verify(models).match(hardware: .any).called(0)
        verify(models).match(deviceType: .value("iPhone 17 Pro"), deviceName: .value("iPhone 17 Pro")).called(1)
        verify(models).match(deviceType: .value("iPhone 17 Pro"), deviceName: .value("my clone")).called(1)
    }
}
