import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

// iPhone Duo's model is Apple's own: `V68.usdz` inside Xcode's DeviceKit
// plug-in, a skinned book whose `l_over_r` clip shuts it, with the
// unfolded screen and the cover as two materials. The definition names
// all of that, and says the asset lives in Xcode rather than beside it.
@Suite("Foldable model definition")
struct FoldableModelDefinitionTests {

    @Test func `should read the fold's shutting clip, shut time, cover material and rest rotation`() throws {
        let model = try DeviceModelDefinition.parsing(json: Data(Self.duoJSON.utf8))

        let fold = try #require(model.scene.fold)
        #expect(fold.clip == "l_over_r")
        #expect(fold.shutTime == 5.0)
        #expect(fold.coverMaterial == "YqugYDOqMSOpqyA")
        #expect(fold.coverTextureSize == RenderDimensions(width: 1398, height: 2034))
        #expect(fold.openPoseDegrees == 130)
        #expect(model.scene.restRotation == DeviceRotation(x: 90, y: 0, z: 0))
    }

    @Test func `should accept a quarter-turn screen texture rotation and reject other angles`() throws {
        let model = try DeviceModelDefinition.parsing(json: Data(Self.duoJSON.utf8))

        #expect(model.scene.textureRotation == 90)
        #expect(model.scene.fold?.coverTextureRotation == 0)

        let odd = Self.duoJSON.replacingOccurrences(of: #""textureRotation": 90"#, with: #""textureRotation": 45"#)
        #expect(throws: DeviceModelError.invalidTextureRotation(45)) {
            try DeviceModelDefinition.parsing(json: Data(odd.utf8))
        }
    }

    @Test func `should name each hardware button by its joint and reject a nameless one`() throws {
        let model = try DeviceModelDefinition.parsing(json: Data(Self.duoJSON.utf8))

        #expect(model.scene.buttons == [
            DeviceModelButton(id: "power", joint: "oknVLIOxyFKJJzk"),
            DeviceModelButton(id: "volume-up", joint: "xsdEUgktlZKTjeM"),
        ])
        let nameless = Self.duoJSON.replacingOccurrences(of: #""id": "power""#, with: #""id": """#)
        #expect(throws: DeviceModelError.emptyField("scene.buttons")) {
            try DeviceModelDefinition.parsing(json: Data(nameless.utf8))
        }
    }

    @Test func `should give a flat device no fold and no rest rotation`() throws {
        let model = try DeviceModelDefinition.parsing(json: DeviceModelDefinitionTests.macBook)

        #expect(model.scene.fold == nil)
        #expect(model.scene.restRotation == nil)
    }

    @Test func `should name an asset that lives in Xcode by its path under Contents`() throws {
        let model = try DeviceModelDefinition.parsing(json: Data(Self.duoJSON.utf8))

        #expect(model.asset.file == nil)
        #expect(model.asset.xcodeResource
            == "SharedFrameworks/DeviceKit.framework/Versions/A/PlugIns/CoreDevicePopDeviceKitExtension.devicekitplugin/Contents/Resources/V68.usdz")
    }

    @Test func `should reject a fold without a clip or a positive shut time`() throws {
        let noClip = Self.duoJSON.replacingOccurrences(of: #""clip": "l_over_r""#, with: #""clip": """#)
        #expect(throws: DeviceModelError.emptyField("scene.fold.clip")) {
            try DeviceModelDefinition.parsing(json: Data(noClip.utf8))
        }
        let noTime = Self.duoJSON.replacingOccurrences(of: #""shutTime": 5.0"#, with: #""shutTime": 0"#)
        #expect(throws: DeviceModelError.invalidFold) {
            try DeviceModelDefinition.parsing(json: Data(noTime.utf8))
        }
    }

    static let duoJSON = #"""
    {
      "schemaVersion": 1,
      "id": "iphone-duo",
      "displayName": "iPhone Duo",
      "matches": {
        "simulatorDeviceTypes": ["com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"],
        "deviceNames": ["iPhone Duo"]
      },
      "asset": {
        "xcodeResource": "SharedFrameworks/DeviceKit.framework/Versions/A/PlugIns/CoreDevicePopDeviceKitExtension.devicekitplugin/Contents/Resources/V68.usdz"
      },
      "scene": {
        "rootNode": "root",
        "screenNode": null,
        "screenMaterial": "CvyXbAGXoolRUYl",
        "nativeOrientation": "landscape",
        "textureSize": {"width": 2007, "height": 2853},
        "usesScreenOverlay": false,
        "textureRotation": 90,
        "restRotation": {"x": 90, "y": 0, "z": 0},
        "buttons": [
          {"id": "power", "joint": "oknVLIOxyFKJJzk"},
          {"id": "volume-up", "joint": "xsdEUgktlZKTjeM"}
        ],
        "fold": {
          "clip": "l_over_r",
          "shutTime": 5.0,
          "coverMaterial": "YqugYDOqMSOpqyA",
          "coverTextureSize": {"width": 1398, "height": 2034},
          "coverTextureRotation": 0,
          "openPoseDegrees": 130
        }
      },
      "variantSets": []
    }
    """#
}
