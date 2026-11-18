import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("Device3DCamera")
struct Device3DCameraTests {
    @Test func `should read a set_3d_camera envelope as a live camera rotation and zoom`() throws {
        let camera = try #require(try Device3DCamera.parsing(json: Data(#"""
        {
          "type": "set_3d_camera",
          "rotation": {"x": -12, "y": 31, "z": 2},
          "zoom": 1.25
        }
        """#.utf8)))

        #expect(camera == Device3DCamera(
            rotation: DeviceRotation(x: -12, y: 31, z: 2),
            zoom: 1.25
        ))
    }

    @Test func `should carry the guest's interface orientation when the page turns a foldable`() throws {
        // The book stands the way the guest is held; the page names the
        // orientation it asked the guest for, so the lit screen's pieces
        // are ordered as that framebuffer is drawn.
        let camera = try #require(try Device3DCamera.parsing(json: Data(#"""
        {"type": "set_3d_camera", "rotation": {"x": 0, "y": 0, "z": 90}, "zoom": 1,
         "orientation": "portrait"}
        """#.utf8)))
        #expect(camera.orientation == .portrait)
        #expect(try Device3DCamera.parsing(json: Data(#"""
        {"type": "set_3d_camera", "rotation": {"x": 0, "y": 0, "z": 0}, "zoom": 1}
        """#.utf8))?.orientation == nil)
        #expect(throws: DeviceModelError.invalidRenderOptions) {
            _ = try Device3DCamera.parsing(json: Data(#"""
            {"type": "set_3d_camera", "rotation": {"x": 0, "y": 0, "z": 0}, "zoom": 1,
             "orientation": "sideways"}
            """#.utf8))
        }
    }

    @Test func `should ignore envelopes owned by another control`() throws {
        #expect(try Device3DCamera.parsing(
            json: Data(#"{"type":"set_fps","fps":30}"#.utf8)
        ) == nil)
    }

    @Test func `should reject unsafe camera rotation and zoom values`() {
        #expect(throws: DeviceModelError.invalidRenderOptions) {
            _ = try Device3DCamera.parsing(json: Data(#"""
            {
              "type": "set_3d_camera",
              "rotation": {"x": 91, "y": 0, "z": 0},
              "zoom": 1
            }
            """#.utf8))
        }
        #expect(throws: DeviceModelError.invalidRenderOptions) {
            _ = try Device3DCamera.parsing(json: Data(#"""
            {
              "type": "set_3d_camera",
              "rotation": {"x": 0, "y": 0, "z": 0},
              "zoom": 0
            }
            """#.utf8))
        }
    }

}
