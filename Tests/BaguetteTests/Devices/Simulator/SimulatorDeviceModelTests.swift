import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("Simulator 3D model")
struct SimulatorDeviceModelTests {

    @Test func `should keep a renamed simulator's hardware model`() throws {
        let simulator = MockSimulator()
        given(simulator).deviceTypeName.willReturn("iPhone 17 Pro")
        given(simulator).name.willReturn("Team QA iPhone")
        given(simulator).runtime.willReturn("iOS 26.4")
        let installed = Self.installed(matches: DeviceModelMatches(deviceNames: ["iPhone 17 Pro"]))
        let catalog = try DeviceModelCatalog(layers: [[installed]])

        #expect(try SimulatorDevice(simulator).model3D(in: catalog) == installed)
    }

    @Test func `should resolve a model from the stable device type and visible name`() throws {
        let simulator = MockSimulator()
        let models = MockDeviceModels()
        let installed = Self.installed()
        given(simulator).deviceTypeName.willReturn("iPhone 17 Pro")
        given(simulator).name.willReturn("Demo Phone")
        given(simulator).runtime.willReturn("iOS 26.4")
        given(models).match(
            deviceType: .value("iPhone 17 Pro"),
            deviceName: .value("iPhone 17 Pro")
        ).willReturn(nil)
        given(models).match(
            deviceType: .value("iPhone 17 Pro"),
            deviceName: .value("Demo Phone")
        ).willReturn(installed)

        let found = try SimulatorDevice(simulator).model3D(in: models)

        #expect(found == installed)
        verify(models).match(
            deviceType: .value("iPhone 17 Pro"),
            deviceName: .value("Demo Phone")
        ).called(1)
    }
}

private extension SimulatorDeviceModelTests {
    static func installed(matches: DeviceModelMatches = DeviceModelMatches()) -> InstalledDeviceModel {
        InstalledDeviceModel(
            definition: DeviceModelDefinition(
                schemaVersion: 1,
                id: "iphone-17-pro",
                displayName: "iPhone 17 Pro",
                matches: matches,
                asset: DeviceModelAsset(file: "device.usdz", downloadURL: nil, sha256: nil),
                scene: DeviceModelScene(
                    rootNode: "Device",
                    screenNode: "Screen",
                    screenMaterial: "Screen",
                    nativeOrientation: .portrait,
                    textureSize: RenderDimensions(width: 1179, height: 2556),
                    usesScreenOverlay: false
                ),
                variantSets: []
            ),
            directoryURL: URL(fileURLWithPath: "/models/iphone")
        )
    }
}
