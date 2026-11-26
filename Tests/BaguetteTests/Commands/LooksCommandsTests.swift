import CoreVideo
import Foundation
import IOSurface
import ImageIO
import Mockable
import Testing
import UniformTypeIdentifiers
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// `baguette chrome` and `render-3d` run against the devices, chrome and
/// 3D models a test hands them.
@Suite("Looks commands")
struct LooksCommandsTests {

    private static let assets = DeviceChromeAssets(
        chrome: DeviceChrome(
            identifier: "phone11",
            screenInsets: Insets(top: 18, left: 18, bottom: 18, right: 18),
            outerCornerRadius: 80, buttons: [], compositeImageName: "PhoneComposite"),
        composite: ChromeImage(data: Data("PNG".utf8), size: Size(width: 100, height: 200)))

    private func chromes(_ assets: DeviceChromeAssets? = Self.assets) -> MockChromes {
        let chromes = MockChromes()
        given(chromes).panels(forDeviceName: .any).willReturn([.primary])
        given(chromes).assets(forDeviceName: .any).willReturn(assets)
        given(chromes).assets(forDeviceName: .any, panel: .any).willReturn(assets)
        return chromes
    }

    private func chrome(_ argv: [String], chromes: MockChromes, on devices: any Devices = routeDevices())
        async throws -> CommandRun
    {
        try await ChromeCommand.$chromes.withValue(chromes) {
            try await run(reaching: reaching(devices)) {
                if argv.first == "layout" {
                    try ChromeCommand.Layout.parse(Array(argv.dropFirst())).run()
                } else {
                    try ChromeCommand.Composite.parse(Array(argv.dropFirst())).run()
                }
            }
        }
    }

    // MARK: - chrome

    @Test func `should answer the layout of the device named`() async throws {
        let ran = try await chrome(["layout", "--device-name", "iPhone 17"], chromes: chromes())

        #expect(ran.said == [Self.assets.layoutJSON()])
    }

    @Test func `should answer the layout of the device the udid names`() async throws {
        let ran = try await chrome(["layout", "--udid", "U"], chromes: chromes())

        #expect(ran.said == [Self.assets.layoutJSON()])
    }

    @Test func `should answer the named panel's layout of the device the udid names`() async throws {
        let ran = try await chrome(["layout", "--udid", "U", "--panel", "cover"], chromes: chromes())

        #expect(ran.said == [Self.assets.layoutJSON()])
    }

    @Test func `should refuse a udid no device has`() async throws {
        await #expect(throws: ChromeCommandError.simulatorNotFound(udid: "NOPE")) {
            try await chrome(["layout", "--udid", "NOPE"], chromes: chromes())
        }
    }

    @Test func `should refuse a device no chrome bundle covers`() async throws {
        await #expect(throws: ChromeCommandError.notFound(target: #""Apple TV""#)) {
            try await chrome(["layout", "--device-name", "Apple TV"], chromes: chromes(nil))
        }
    }

    @Test func `should write the composite bezel's bytes`() async throws {
        let ran = try await chrome(["composite", "--device-name", "iPhone 17"], chromes: chromes())

        #expect(ran.written == Data("PNG".utf8))
    }

    @Test func `should refuse a composite no chrome bundle covers`() async throws {
        await #expect(throws: ChromeCommandError.notFound(target: #""Apple TV""#)) {
            try await chrome(["composite", "--device-name", "Apple TV"], chromes: chromes(nil))
        }
    }

    // MARK: - render-3d

    private static let installed = InstalledDeviceModel(
        definition: DeviceModelDefinition(
            schemaVersion: 1, id: "iphone-17", displayName: "iPhone 17", matches: DeviceModelMatches(),
            asset: DeviceModelAsset(file: "device.usdz", downloadURL: nil, sha256: nil),
            scene: DeviceModelScene(
                rootNode: "Device", screenNode: "Screen", screenMaterial: "Screen",
                nativeOrientation: .portrait, textureSize: RenderDimensions(width: 40, height: 80),
                usesScreenOverlay: false, fold: nil),
            variantSets: []),
        directoryURL: URL(fileURLWithPath: "/models/iphone-17"))

    private func models(_ installed: InstalledDeviceModel? = Self.installed) -> MockDeviceModels {
        let models = MockDeviceModels()
        given(models).find(id: .any).willReturn(installed)
        given(models).match(deviceType: .any, deviceName: .any).willReturn(installed)
        given(models).match(hardware: .any).willReturn(installed)
        return models
    }

    private func renderer() -> MockDeviceRenderer {
        let renderer = MockDeviceRenderer()
        given(renderer).render(plan: .any, screenImage: .any).willReturn(Data("RENDERED".utf8))
        return renderer
    }

    private func render(_ argv: [String], models: MockDeviceModels, on devices: any Devices = routeDevices())
        async throws -> CommandRun
    {
        try await Render3DCommand.$models.withValue(models) {
            try await Render3DCommand.$renderer.withValue(renderer()) {
                try await run(try Render3DCommand.parse(argv), on: devices)
            }
        }
    }

    private func screenFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screen-\(UUID()).png")
        let context = try #require(CGContext(
            data: nil, width: 4, height: 8, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func `should render a screenshot on the model named and write the image`() async throws {
        let screen = try screenFile()
        defer { try? FileManager.default.removeItem(at: screen) }

        let ran = try await render(["--screen", screen.path, "--device", "iphone-17"], models: models())

        #expect(ran.written == Data("RENDERED".utf8))
    }

    @Test func `should write the render to the file given`() async throws {
        let screen = try screenFile()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("render-\(UUID()).png")
        defer {
            try? FileManager.default.removeItem(at: screen)
            try? FileManager.default.removeItem(at: output)
        }

        _ = try await render(["--screen", screen.path, "--device", "iphone-17", "-o", output.path,
                              "--background", "#101820", "--size", "80x160"], models: models())

        #expect(try Data(contentsOf: output) == Data("RENDERED".utf8))
    }

    @Test func `should refuse a model that isn't installed`() async throws {
        let screen = try screenFile()
        defer { try? FileManager.default.removeItem(at: screen) }

        await #expect(throws: DeviceModelError.modelNotFound("nope")) {
            try await render(["--screen", screen.path, "--device", "nope"], models: models(nil))
        }
    }

    @Test func `should refuse a screen image that isn't a PNG or JPEG`() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("screen-\(UUID()).png")
        try Data("not an image".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect(throws: DeviceModelError.screenImageInvalid) {
            try await render(["--screen", file.path, "--device", "iphone-17"], models: models())
        }
    }

    private func capturing() throws -> any Devices {
        let surface = try #require(IOSurface(properties: [
            .width: 4, .height: 8, .bytesPerElement: 4, .bytesPerRow: 16,
            .pixelFormat: kCVPixelFormatType_32BGRA, .allocSize: 128,
        ]))
        let screen = MockScreen()
        given(screen).start(onFrame: .any).willProduce { onFrame in onFrame(surface) }
        given(screen).stop().willReturn(())
        return routeDevices { $0.register(.screen) { screen } }
    }

    @Test func `should render the device's live screen on its own model`() async throws {
        let ran = try await render(["--udid", "U"], models: models(), on: try capturing())

        #expect(ran.written == Data("RENDERED".utf8))
    }

    @Test func `should render the device's live screen on the model named`() async throws {
        let ran = try await render(["--udid", "U", "--device", "iphone-17"], models: models(), on: try capturing())

        #expect(ran.written == Data("RENDERED".utf8))
    }

    @Test func `should refuse a live render when no model matches the device`() async throws {
        await #expect(throws: DeviceModelError.noModelForDevice("iPhone 17")) {
            try await render(["--udid", "U"], models: models(nil), on: try capturing())
        }
    }

    @Test func `should refuse a live render on a model that isn't installed`() async throws {
        await #expect(throws: DeviceModelError.modelNotFound("nope")) {
            try await render(["--udid", "U", "--device", "nope"], models: models(nil), on: try capturing())
        }
    }

    @Test func `should refuse a live render of a udid no simulator has`() async throws {
        await #expect(throws: SimulatorError.notFound(udid: "NOPE")) {
            try await render(["--udid", "NOPE"], models: models(), on: try capturing())
        }
    }

    @Test func `should exit 1 rendering a device with no screen`() async throws {
        let ran = try await render(["--udid", "U"], models: models())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do screen"])
    }
}
