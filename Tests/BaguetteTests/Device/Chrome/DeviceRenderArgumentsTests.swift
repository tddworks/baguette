import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("DeviceRenderArguments")
struct DeviceRenderArgumentsTests {

    @Test func `should read rotation, size and repeatable variants`() throws {
        #expect(try DeviceRenderArguments.rotation("-30,45,30")
            == DeviceRotation(x: -30, y: 45, z: 30))
        #expect(try DeviceRenderArguments.captureSize("1200x900")
            .resolve(source: RenderDimensions(width: 1179, height: 2556))
            == RenderDimensions(width: 1200, height: 900))
        #expect(try DeviceRenderArguments.variants([
            "finish=space-black", "keyboard=iso"
        ]) == [
            "finish": "space-black",
            "keyboard": "iso"
        ])
    }

    @Test func `should reject a malformed rotation`() {
        #expect(throws: DeviceModelError.invalidRotationArgument("20,10")) {
            _ = try DeviceRenderArguments.rotation("20,10")
        }
    }

    @Test func `should reject a malformed size`() {
        #expect(throws: DeviceModelError.invalidSizeArgument("1200")) {
            _ = try DeviceRenderArguments.captureSize("1200")
        }
    }

    @Test func `should reject choosing the same variant twice`() {
        #expect(throws: DeviceModelError.duplicateVariantSelection("finish")) {
            _ = try DeviceRenderArguments.variants([
                "finish=black", "finish=silver"
            ])
        }
    }

    @Test func `should accept a size preset where pixels used to be required`() throws {
        #expect(try DeviceRenderArguments.captureSize("appstore-6.9")
            .resolve(source: RenderDimensions(width: 1179, height: 2556))
            == RenderDimensions(width: 1290, height: 2796))
    }

    @Test func `should resolve a ratio size against the captured screen`() throws {
        #expect(try DeviceRenderArguments.captureSize("square")
            .resolve(source: RenderDimensions(width: 1290, height: 2796))
            == RenderDimensions(width: 2796, height: 2796))
        #expect(try DeviceRenderArguments.captureSize("3:2")
            .resolve(source: RenderDimensions(width: 1200, height: 900))
            == RenderDimensions(width: 1350, height: 900))
    }

    @Test func `should default to the captured screen size when no size is asked for`() {
        #expect(CaptureSize.native
            .resolve(source: RenderDimensions(width: 1179, height: 2556))
            == RenderDimensions(width: 1179, height: 2556))
    }

    @Test func `should reject an unknown size preset as a malformed size`() {
        #expect(throws: DeviceModelError.invalidSizeArgument("nonsense")) {
            _ = try DeviceRenderArguments.captureSize("nonsense")
        }
    }
}
