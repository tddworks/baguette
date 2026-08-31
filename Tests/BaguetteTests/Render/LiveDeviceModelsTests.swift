import Foundation
import Testing
@testable import Baguette

@Suite("LiveDeviceModels")
struct LiveDeviceModelsTests {

    @Test func `discovers model bundles and preserves configured root precedence`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let overrideRoot = scratch.appending(path: "override")
        let bundledRoot = scratch.appending(path: "bundled")
        try Self.installModel(id: "phone", displayName: "Override", in: overrideRoot)
        try Self.installModel(id: "phone", displayName: "Bundled", in: bundledRoot)

        let models = try LiveDeviceModels(rootURLs: [overrideRoot, bundledRoot])
        let found = try #require(try models.find(id: "phone"))

        #expect(found.definition.displayName == "Override")
        #expect(found.directoryURL.lastPathComponent == "phone")
    }

    @Test func `ignores root entries that are not model bundles`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appending(path: "models")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: root.appending(path: "README.txt"))
        try FileManager.default.createDirectory(
            at: root.appending(path: "unfinished"),
            withIntermediateDirectories: true
        )
        try Self.installModel(id: "phone", displayName: "Phone", in: root)

        let models = try LiveDeviceModels(rootURLs: [root])

        #expect(try models.find(id: "phone") != nil)
        #expect(try models.find(id: "unfinished") == nil)
    }

    @Test func `missing configured roots are empty precedence layers`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let missing = scratch.appending(path: "not-installed")

        let models = try LiveDeviceModels(rootURLs: [missing])

        #expect(try models.find(id: "phone") == nil)
    }

    @Test func `reports the definition path when an installed bundle is malformed`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appending(path: "models")
        let bundle = root.appending(path: "broken")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let definition = bundle.appending(path: "definition.json")
        try Data("{broken".utf8).write(to: definition)

        do {
            _ = try LiveDeviceModels(rootURLs: [root])
            Issue.record("expected malformed definition to fail discovery")
        } catch let DeviceModelError.malformedDefinition(path) {
            #expect(path.hasSuffix("/models/broken/definition.json"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func `matches a physical device by hardware id from an installed bundle`() throws {
        // The device-twin path end to end at this layer: `deviceModels`
        // written in a bundle's definition.json on disk, discovered,
        // and matched by the companion's hardware identifier.
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appending(path: "models")
        try Self.installModel(
            id: "iphone-13-pro-max", displayName: "iPhone 13 Pro Max",
            deviceModels: ["iPhone14,3"], in: root
        )

        let models = try LiveDeviceModels(rootURLs: [root])

        #expect(try models.match(hardware: "iPhone14,3")?.definition.id == "iphone-13-pro-max")
        #expect(try models.match(hardware: "iPhone18,1") == nil)
    }

    @Test func `all lists installed bundles with higher roots shadowing by id`() throws {
        // Powers the picker offered when no definition matches a
        // phone's hardware.
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let overrideRoot = scratch.appending(path: "override")
        let bundledRoot = scratch.appending(path: "bundled")
        try Self.installModel(id: "phone", displayName: "Override", in: overrideRoot)
        try Self.installModel(id: "phone", displayName: "Bundled", in: bundledRoot)
        try Self.installModel(id: "tablet", displayName: "Tablet", in: bundledRoot)

        let models = try LiveDeviceModels(rootURLs: [overrideRoot, bundledRoot])
        let all = try models.all()

        #expect(all.map(\.definition.id.rawValue).sorted() == ["phone", "tablet"])
        #expect(all.first { $0.definition.id == "phone" }?.definition.displayName == "Override")
    }
}

private extension LiveDeviceModelsTests {
    static func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "baguette-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func installModel(
        id: String,
        displayName: String,
        deviceModels: [String] = [],
        in root: URL
    ) throws {
        let bundle = root.appending(path: id)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let json = """
        {
          "schemaVersion": 1,
          "id": "\(id)",
          "displayName": "\(displayName)",
          "matches": {
            "simulatorDeviceTypes": [],
            "deviceNames": ["iPhone 17 Pro"],
            "deviceModels": [\(deviceModels.map { "\"\($0)\"" }.joined(separator: ","))]
          },
          "asset": {"file": "device.usdz"},
          "scene": {
            "rootNode": "Device",
            "screenNode": "Screen",
            "screenMaterial": "Screen",
            "nativeOrientation": "portrait",
            "textureSize": {"width": 1179, "height": 2556},
            "usesScreenOverlay": false
          },
          "variantSets": []
        }
        """
        try Data(json.utf8).write(to: bundle.appending(path: "definition.json"))
    }
}
