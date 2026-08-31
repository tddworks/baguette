import Foundation
import Testing
@testable import Baguette

@Suite("DeviceModelCatalog")
struct DeviceModelCatalogTests {

    @Test func `find by id prefers the definition from the highest precedence layer`() throws {
        let bundled = Self.installed(id: "phone", displayName: "Bundled", directory: "/bundle")
        let override = Self.installed(id: "phone", displayName: "Override", directory: "/override")
        let catalog = try DeviceModelCatalog(layers: [[override], [bundled]])

        let found = try #require(catalog.find(id: "phone"))

        #expect(found.definition.displayName == "Override")
        #expect(found.directoryURL.path == "/override")
    }

    @Test func `match prefers a matching definition from the highest precedence layer`() throws {
        let bundled = Self.installed(
            id: "generic-phone", displayName: "Bundled", directory: "/bundle",
            deviceNames: ["iPhone 17 Pro"]
        )
        let override = Self.installed(
            id: "custom-phone", displayName: "Override", directory: "/override",
            deviceNames: ["iPhone 17 Pro"]
        )
        let catalog = try DeviceModelCatalog(layers: [[override], [bundled]])

        let matched = try catalog.match(deviceType: "unknown", deviceName: "iPhone 17 Pro")
        let found = try #require(matched)

        #expect(found.definition.id == "custom-phone")
    }

    @Test func `match returns nil when no definition supports the device`() throws {
        let catalog = try DeviceModelCatalog(layers: [[
            Self.installed(id: "phone", displayName: "Phone", directory: "/bundle")
        ]])

        #expect(try catalog.match(deviceType: "unknown", deviceName: "Unknown") == nil)
    }

    @Test func `rejects two matching definitions in the same precedence layer`() {
        let first = Self.installed(
            id: "first", displayName: "First", directory: "/models/first",
            deviceNames: ["iPhone 17 Pro"]
        )
        let second = Self.installed(
            id: "second", displayName: "Second", directory: "/models/second",
            deviceNames: ["iPhone 17 Pro"]
        )
        let catalog = try! DeviceModelCatalog(layers: [[first, second]])

        #expect(throws: DeviceModelError.ambiguousMatch(["first", "second"])) {
            _ = try catalog.match(deviceType: "unknown", deviceName: "iPhone 17 Pro")
        }
    }

    @Test func `duplicate ids in one layer are rejected when catalog is built`() {
        let first = Self.installed(id: "phone", displayName: "First", directory: "/models/first")
        let second = Self.installed(id: "phone", displayName: "Second", directory: "/models/second")

        #expect(throws: DeviceModelError.duplicateModelID("phone")) {
            _ = try DeviceModelCatalog(layers: [[first, second]])
        }
    }
}

private extension DeviceModelCatalogTests {
    static func installed(
        id: DeviceModelID,
        displayName: String,
        directory: String,
        deviceNames: [String] = []
    ) -> InstalledDeviceModel {
        InstalledDeviceModel(
            definition: DeviceModelDefinition(
                schemaVersion: 1,
                id: id,
                displayName: displayName,
                matches: DeviceModelMatches(deviceNames: deviceNames),
                asset: DeviceModelAsset(file: "device.usdz", downloadURL: nil, sha256: nil),
                scene: DeviceModelScene(
                    rootNode: "Device",
                    screenNode: "Screen",
                    screenMaterial: "Screen",
                    nativeOrientation: .portrait,
                    textureSize: RenderDimensions(width: 100, height: 200),
                    usesScreenOverlay: false
                ),
                variantSets: []
            ),
            directoryURL: URL(fileURLWithPath: directory)
        )
    }
}

extension DeviceModelCatalogTests {
    static func installedHardware(
        id: DeviceModelID, displayName: String, directory: String, deviceModels: [String]
    ) -> InstalledDeviceModel {
        InstalledDeviceModel(
            definition: DeviceModelDefinition(
                schemaVersion: 1,
                id: id,
                displayName: displayName,
                matches: DeviceModelMatches(deviceModels: deviceModels),
                asset: DeviceModelAsset(file: "device.usdz", downloadURL: nil, sha256: nil),
                scene: DeviceModelScene(
                    rootNode: "Device", screenNode: "Screen", screenMaterial: "Screen",
                    nativeOrientation: .portrait,
                    textureSize: RenderDimensions(width: 100, height: 200),
                    usesScreenOverlay: false
                ),
                variantSets: []
            ),
            directoryURL: URL(fileURLWithPath: directory)
        )
    }

    @Test func `match by hardware prefers the highest precedence layer`() throws {
        let bundled = Self.installedHardware(
            id: "stock", displayName: "Stock", directory: "/bundle", deviceModels: ["iPhone14,3"]
        )
        let override = Self.installedHardware(
            id: "custom", displayName: "Custom", directory: "/override", deviceModels: ["iPhone14,3"]
        )
        let catalog = try DeviceModelCatalog(layers: [[override], [bundled]])
        #expect(try catalog.match(hardware: "iPhone14,3")?.definition.id == "custom")
    }

    @Test func `match by hardware returns nil when nothing declares it`() throws {
        let catalog = try DeviceModelCatalog(layers: [[
            Self.installed(id: "phone", displayName: "Phone", directory: "/bundle")
        ]])
        #expect(try catalog.match(hardware: "iPhone14,3") == nil)
    }

    @Test func `rejects two hardware matches in the same layer`() throws {
        let first = Self.installedHardware(
            id: "first", displayName: "First", directory: "/a", deviceModels: ["iPhone14,3"]
        )
        let second = Self.installedHardware(
            id: "second", displayName: "Second", directory: "/b", deviceModels: ["iPhone14,3"]
        )
        let catalog = try DeviceModelCatalog(layers: [[first, second]])
        #expect(throws: (any Error).self) { _ = try catalog.match(hardware: "iPhone14,3") }
    }

    @Test func `all lists installed models with higher layers shadowing by id`() throws {
        let bundled = Self.installed(id: "phone", displayName: "Bundled", directory: "/bundle")
        let extra = Self.installed(id: "tablet", displayName: "Tablet", directory: "/bundle")
        let override = Self.installed(id: "phone", displayName: "Override", directory: "/override")
        let catalog = try DeviceModelCatalog(layers: [[override], [bundled, extra]])
        let all = catalog.all()
        #expect(all.map(\.definition.id) == ["phone", "tablet"])
        #expect(all.first?.definition.displayName == "Override")
    }
}
