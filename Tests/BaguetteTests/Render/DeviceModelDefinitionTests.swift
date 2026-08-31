import Foundation
import Testing
@testable import Baguette

@Suite("DeviceModelDefinition")
struct DeviceModelDefinitionTests {

    @Test func `parses model identity scene and local asset`() throws {
        let model = try DeviceModelDefinition.parsing(json: Self.macBook)

        #expect(model.id == DeviceModelID("macbook-pro-14-inch"))
        #expect(model.displayName == "MacBook Pro 14-inch")
        #expect(model.matches.deviceNames == ["MacBook Pro 14-inch"])
        #expect(model.asset.file == "device.usdz")
        #expect(model.scene.rootNode == "XCnTRSzLPcVVRyt")
        #expect(model.scene.nativeOrientation == .landscape)
        #expect(model.scene.textureSize == RenderDimensions(width: 3024, height: 1964))
    }

    @Test func `matches a simulator by exact device type or device name`() throws {
        let model = try DeviceModelDefinition.parsing(json: Self.macBook)

        #expect(model.matches(deviceType: "com.apple.CoreSimulator.SimDeviceType.MacBook-Pro-14-inch",
                              deviceName: "Renamed Mac") == true)
        #expect(model.matches(deviceType: "unknown",
                              deviceName: "MacBook Pro 14-inch") == true)
        #expect(model.matches(deviceType: "unknown",
                              deviceName: "MacBook Pro 16-inch") == false)
    }

    @Test func `applies defaults and maps public variant ids onto USD selections`() throws {
        let model = try DeviceModelDefinition.parsing(json: Self.macBook)

        let selections = try model.resolveVariants([:])

        #expect(selections == [
            DeviceVariantSelection(
                setID: "finish",
                primPath: "/XCnTRSzLPcVVRyt",
                usdName: "Color",
                usdValue: "Space_Black"
            )
        ])
    }

    @Test func `explicit variant choice overrides its default`() throws {
        let model = try DeviceModelDefinition.parsing(json: Self.macBook)

        let selections = try model.resolveVariants(["finish": "silver"])

        #expect(selections.map(\.usdValue) == ["Silver"])
    }

    @Test func `resolves declared material appearance for a public variant`() throws {
        let json = Self.macBookJSON.replacingOccurrences(
            of: #""displayName": "Device finish""#,
            with: #"""
            "displayName": "Device finish",
            "kind": "materials"
            """#
        ).replacingOccurrences(
            of: ##""previewColor": "#d3d4d5""##,
            with: ##"""
            "previewColor": "#d3d4d5",
            "materialColors": {
              "DeviceBody": "#5B627C",
              "CameraRing": "#252938"
            }
            """##
        )
        let model = try DeviceModelDefinition.parsing(json: Data(json.utf8))
        let selections = try model.resolveVariants(["finish": "silver"])
        let selection = try #require(selections.first)

        #expect(selection.materialColors == [
            "DeviceBody": "#5B627C",
            "CameraRing": "#252938",
        ])
        #expect(selection.kind == .materials)
    }

    @Test func `rejects an unknown public variant set`() throws {
        let model = try DeviceModelDefinition.parsing(json: Self.macBook)

        #expect(throws: DeviceModelError.unknownVariantSet("keyboard")) {
            _ = try model.resolveVariants(["keyboard": "visible"])
        }
    }

    @Test func `rejects an unknown public variant choice`() throws {
        let model = try DeviceModelDefinition.parsing(json: Self.macBook)

        #expect(throws: DeviceModelError.unknownVariantChoice(
            set: "finish", choice: "gold", allowed: ["space-black", "silver"]
        )) {
            _ = try model.resolveVariants(["finish": "gold"])
        }
    }

    @Test func `rejects an unsupported schema version`() {
        let json = Self.macBookJSON.replacingOccurrences(
            of: #""schemaVersion": 1"#,
            with: #""schemaVersion": 2"#
        )

        #expect(throws: DeviceModelError.unsupportedSchemaVersion(2)) {
            _ = try DeviceModelDefinition.parsing(json: Data(json.utf8))
        }
    }

    @Test func `rejects duplicate variant set ids`() {
        let duplicate = Self.macBookJSON.replacingOccurrences(
            of: #""variantSets": ["#,
            with: #"""
            "variantSets": [
              {
                "id": "finish",
                "displayName": "Duplicate",
                "primPath": "/Device",
                "usdName": "Other",
                "default": "plain",
                "choices": [
                  {"id":"plain","displayName":"Plain","usdValue":"Plain"}
                ]
              },
            """#
        )

        #expect(throws: DeviceModelError.duplicateVariantSet("finish")) {
            _ = try DeviceModelDefinition.parsing(json: Data(duplicate.utf8))
        }
    }

    @Test func `rejects a default that is not one of the declared choices`() {
        let invalid = Self.macBookJSON.replacingOccurrences(
            of: #""default": "space-black""#,
            with: #""default": "gold""#
        )

        #expect(throws: DeviceModelError.invalidVariantDefault(set: "finish", choice: "gold")) {
            _ = try DeviceModelDefinition.parsing(json: Data(invalid.utf8))
        }
    }

    @Test func `rejects a downloaded asset without a sha256`() throws {
        var object = try #require(
            JSONSerialization.jsonObject(with: Self.macBook) as? [String: Any]
        )
        var asset = try #require(object["asset"] as? [String: Any])
        asset.removeValue(forKey: "sha256")
        object["asset"] = asset
        let missingHash = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DeviceModelError.downloadRequiresSHA256) {
            _ = try DeviceModelDefinition.parsing(json: missingHash)
        }
    }
}

private extension DeviceModelDefinitionTests {
    static var macBook: Data { Data(macBookJSON.utf8) }

    static let macBookJSON = #"""
    {
      "schemaVersion": 1,
      "id": "macbook-pro-14-inch",
      "displayName": "MacBook Pro 14-inch",
      "matches": {
        "simulatorDeviceTypes": [
          "com.apple.CoreSimulator.SimDeviceType.MacBook-Pro-14-inch"
        ],
        "deviceNames": ["MacBook Pro 14-inch"]
      },
      "asset": {
        "file": "device.usdz",
        "downloadURL": "https://example.com/device.usdz",
        "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      },
      "scene": {
        "rootNode": "XCnTRSzLPcVVRyt",
        "screenNode": "Screen",
        "screenMaterial": "ScreenMaterial",
        "nativeOrientation": "landscape",
        "textureSize": {"width": 3024, "height": 1964},
        "usesScreenOverlay": false
      },
      "variantSets": [
        {
          "id": "finish",
          "displayName": "Device finish",
          "primPath": "/XCnTRSzLPcVVRyt",
          "usdName": "Color",
          "default": "space-black",
          "choices": [
            {
              "id": "space-black",
              "displayName": "Space Black",
              "usdValue": "Space_Black",
              "previewColor": "#2f3033"
            },
            {
              "id": "silver",
              "displayName": "Silver",
              "usdValue": "Silver",
              "previewColor": "#d3d4d5"
            }
          ]
        }
      ]
    }
    """#
}

extension DeviceModelDefinitionTests {
    @Test func `matches a physical device by hardware identifier`() throws {
        let json = """
        {"schemaVersion":1,"id":"iphone-13-pro-max","displayName":"iPhone 13 Pro Max",
         "matches":{"simulatorDeviceTypes":[],"deviceNames":[],"deviceModels":["iPhone14,3"]},
         "asset":{"file":"device.usdz"},
         "scene":{"rootNode":"Device","screenNode":"Screen","screenMaterial":"Screen",
                  "nativeOrientation":"portrait","textureSize":{"width":1284,"height":2778},
                  "usesScreenOverlay":false},
         "variantSets":[]}
        """
        let model = try DeviceModelDefinition.parsing(json: Data(json.utf8))
        #expect(model.matches(hardware: "iPhone14,3") == true)
        #expect(model.matches(hardware: "iPhone17,2") == false)
    }

    @Test func `definitions without deviceModels parse and match no hardware`() throws {
        let model = try DeviceModelDefinition.parsing(json: Self.macBook)
        #expect(model.matches.deviceModels == [])
        #expect(model.matches(hardware: "iPhone14,3") == false)
    }
}
