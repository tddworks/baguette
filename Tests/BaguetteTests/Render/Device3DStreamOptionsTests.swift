import Testing
@testable import Baguette

@Suite("Device3DStreamOptions")
struct Device3DStreamOptionsTests {
    @Test func `empty query uses live stream defaults`() throws {
        let options = try Device3DStreamOptions.parse([:])

        #expect(options.rotation == DeviceRotation(x: -8, y: 18, z: 0))
        #expect(options.variants == [:])
        #expect(options.outputSize == RenderDimensions(width: 960, height: 960))
        #expect(options.fit == .cover)
        #expect(options.background == .color("#eef1f5"))
        #expect(options.screenGlass == false)
    }

    @Test func `parses camera output and repeatable public variants`() throws {
        let options = try Device3DStreamOptions.parse([
            "rotation": ["-12,24,3"],
            "variant": ["finish:deep-blue", "keyboard:ansi"],
            "width": ["1280"],
            "height": ["720"],
            "fit": ["contain"],
            "background": ["transparent"],
            "screenGlass": ["true"],
        ])

        #expect(options.rotation == DeviceRotation(x: -12, y: 24, z: 3))
        #expect(options.variants == [
            "finish": "deep-blue",
            "keyboard": "ansi",
        ])
        #expect(options.outputSize == RenderDimensions(width: 1280, height: 720))
        #expect(options.fit == .contain)
        #expect(options.background == .transparent)
        #expect(options.screenGlass == true)
    }

    @Test func `rejects a malformed screen glass flag`() {
        #expect(throws: DeviceModelError.invalidRenderOptions) {
            _ = try Device3DStreamOptions.parse(["screenGlass": ["shiny"]])
        }
    }

    @Test func `aligns live output dimensions for hardware video codecs`() throws {
        let options = try Device3DStreamOptions.parse([
            "width": ["669"],
            "height": ["1047"],
        ])

        #expect(options.outputSize == RenderDimensions(width: 670, height: 1048))
    }

    @Test func `rejects duplicate variant set selection`() {
        #expect(throws: DeviceModelError.duplicateVariantSelection("finish")) {
            _ = try Device3DStreamOptions.parse([
                "variant": ["finish:deep-blue", "finish:silver"],
            ])
        }
    }

    @Test func `rejects malformed connection options`() {
        #expect(throws: DeviceModelError.invalidRenderOptions) {
            _ = try Device3DStreamOptions.parse(["rotation": ["sideways"]])
        }
        #expect(throws: DeviceModelError.invalidRenderOptions) {
            _ = try Device3DStreamOptions.parse(["width": ["0"]])
        }
        #expect(throws: DeviceModelError.invalidRenderOptions) {
            _ = try Device3DStreamOptions.parse(["fit": ["squash"]])
        }
    }

    @Test func `parses a size preset for the live stream`() throws {
        let options = try Device3DStreamOptions.parse(["size": ["appstore-6.9"]])

        #expect(options.outputSize == RenderDimensions(width: 1290, height: 2796))
    }

    @Test func `resolves a live stream ratio against the requested frame`() throws {
        let options = try Device3DStreamOptions.parse([
            "width": ["1280"],
            "height": ["720"],
            "size": ["square"],
        ])

        #expect(options.outputSize == RenderDimensions(width: 1280, height: 1280))
    }

    @Test func `rejects an unknown live stream size preset`() {
        #expect(throws: DeviceModelError.invalidRenderOptions) {
            _ = try Device3DStreamOptions.parse(["size": ["gigantic"]])
        }
    }
}

extension Device3DStreamOptionsTests {
    @Test func `a stream may name an explicit model for unmatched hardware`() throws {
        let options = try Device3DStreamOptions.parse(["model": ["iphone-17-pro"]])
        #expect(options.model == DeviceModelID("iphone-17-pro"))
    }

    @Test func `the model defaults to nil so matching stays automatic`() throws {
        #expect(try Device3DStreamOptions.parse([:]).model == nil)
    }
}
