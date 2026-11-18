import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("DeviceRenderOptions")
struct DeviceRenderOptionsTests {

    @Test func `should use HTTP render defaults when the body is an empty object`() throws {
        let options = try DeviceRenderOptions.parsing(json: Data("{}".utf8))

        #expect(options.rotation == .zero)
        #expect(options.variants == [:])
        #expect(options.size == nil)
        #expect(options.fit == .cover)
        #expect(options.background == .transparent)
        #expect(options.screenGlass == false)
    }

    @Test func `should read every HTTP render option`() throws {
        let options = try DeviceRenderOptions.parsing(json: Data("""
        {
          "rotation": {"x": -30, "y": 45, "z": 30},
          "variants": {"finish": "space-black"},
          "size": {"width": 1200, "height": 900},
          "fit": "contain",
          "background": "#112233",
          "screenGlass": true
        }
        """.utf8))

        #expect(options.rotation == DeviceRotation(x: -30, y: 45, z: 30))
        #expect(options.variants == ["finish": "space-black"])
        #expect(options.size == RenderDimensions(width: 1200, height: 900))
        #expect(options.fit == .contain)
        #expect(options.background == .color("#112233"))
        #expect(options.screenGlass == true)
    }

    @Test func `should reject malformed HTTP render options`() {
        #expect(throws: DeviceModelError.invalidRenderOptions) {
            _ = try DeviceRenderOptions.parsing(json: Data("""
            {"fit":"tile","size":{"width":0,"height":900}}
            """.utf8))
        }
    }

    @Test func `should accept a size preset name in the render body`() throws {
        let options = try DeviceRenderOptions.parsing(json: Data("""
        {"size": "appstore-6.9"}
        """.utf8))

        #expect(options.captureSize.spec == "appstore-6.9")
        #expect(options.outputSize(source: RenderDimensions(width: 1179, height: 2556))
            == RenderDimensions(width: 1290, height: 2796))
    }

    @Test func `should resolve a ratio size in the render body against the captured screen`() throws {
        let options = try DeviceRenderOptions.parsing(json: Data("""
        {"size": "square"}
        """.utf8))

        #expect(options.outputSize(source: RenderDimensions(width: 1290, height: 2796))
            == RenderDimensions(width: 2796, height: 2796))
    }

    @Test func `should keep the explicit width and height size object`() throws {
        let options = try DeviceRenderOptions.parsing(json: Data("""
        {"size": {"width": 1200, "height": 900}}
        """.utf8))

        #expect(options.size == RenderDimensions(width: 1200, height: 900))
        #expect(options.outputSize(source: RenderDimensions(width: 1179, height: 2556))
            == RenderDimensions(width: 1200, height: 900))
    }

    @Test func `should render at the captured screen size when no size is asked for`() throws {
        let options = try DeviceRenderOptions.parsing(json: Data("{}".utf8))

        #expect(options.captureSize == .native)
        #expect(options.outputSize(source: RenderDimensions(width: 1179, height: 2556))
            == RenderDimensions(width: 1179, height: 2556))
    }

    @Test func `should reject an unknown size preset name`() {
        #expect(throws: DeviceModelError.invalidRenderOptions) {
            _ = try DeviceRenderOptions.parsing(json: Data("""
            {"size": "gigantic"}
            """.utf8))
        }
    }
}
