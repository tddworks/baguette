import CoreVideo
import Foundation
import HTTPTypes
import HummingbirdTesting
import IOSurface
import ImageIO
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// How a device looks — its chrome, bezel, buttons, definition, 3D model —
/// and the stills of its screen, as the router answers them.
@Suite("Serve router: looks and stills")
struct LooksRouterTests {

    // MARK: - fixtures

    private static func assets(mask: ChromeImage? = nil) -> DeviceChromeAssets {
        DeviceChromeAssets(
            chrome: DeviceChrome(
                identifier: "phone11",
                screenInsets: Insets(top: 0, left: 0, bottom: 0, right: 0),
                outerCornerRadius: 0,
                buttons: [
                    ChromeButton(name: "power", imageName: "PWR", anchor: .right, align: .leading,
                                 offset: Point(x: 0, y: 100)),
                ],
                compositeImageName: "PhoneComposite"
            ),
            composite: ChromeImage(data: Data("MERGED-PNG".utf8), size: Size(width: 110, height: 200)),
            bareComposite: ChromeImage(data: Data("BARE-PNG".utf8), size: Size(width: 100, height: 200)),
            buttonImages: ["power": ChromeImage(data: Data("POWER-PNG".utf8), size: Size(width: 10, height: 30))],
            screenMask: mask
        )
    }

    private static func chromes(_ assets: DeviceChromeAssets? = assets()) -> MockChromes {
        let chromes = MockChromes()
        given(chromes).panels(forDeviceName: .any).willReturn([.primary])
        given(chromes).assets(forDeviceName: .any).willReturn(assets)
        given(chromes).assets(forDeviceName: .any, panel: .any).willReturn(assets)
        return chromes
    }

    /// A screen that hands over one host-allocated BGRA frame.
    private static func screen() -> MockScreen {
        let surface = IOSurface(properties: [
            .width: 40, .height: 80, .bytesPerElement: 4, .bytesPerRow: 160,
            .pixelFormat: kCVPixelFormatType_32BGRA, .allocSize: 40 * 80 * 4,
        ])!
        let screen = MockScreen()
        given(screen).start(onFrame: .any).willProduce { onFrame in onFrame(surface) }
        given(screen).stop().willReturn(())
        return screen
    }

    private static func failingScreen() -> MockScreen {
        let screen = MockScreen()
        given(screen).start(onFrame: .any).willThrow(RoleFailed())
        given(screen).stop().willReturn(())
        return screen
    }

    private static func firstButtonURL(_ response: TestResponse) -> String? {
        (response.json["buttons"] as? [[String: Any]])?.first?["imageUrl"] as? String
    }

    // MARK: - chrome

    @Test func `should lay out the chrome with button URLs on the tree it was asked on`() async throws {
        try await InProcessServer(chromes: Self.chromes()).test { client in
            let devices = try await client.send(.get, "/devices/U/chrome.json")
            let simulators = try await client.send(.get, "/simulators/U/chrome.json")

            #expect(devices.status == .ok)
            #expect(Self.firstButtonURL(devices) == "/devices/U/chrome-button/power.png")
            #expect(Self.firstButtonURL(simulators) == "/simulators/U/chrome-button/power.png")
        }
    }

    @Test func `should serve no chrome for a device with none or no device`() async throws {
        try await InProcessServer(chromes: Self.chromes(nil)).test { client in
            #expect(await client.status(.get, "/devices/U/chrome.json") == .notFound)
            #expect(await client.status(.get, "/devices/ghost/chrome.json") == .notFound)
        }
    }

    @Test func `should describe the device for the SDK bootstrap`() async throws {
        try await InProcessServer(chromes: Self.chromes()).test { client in
            let response = try await client.send(.get, "/devices/U/definition.json?panel=primary")

            #expect(response.status == .ok)
            #expect(response.text.contains("\"U\""))
        }
    }

    @Test func `should borrow the bezel a page picks for its definition`() async throws {
        try await InProcessServer(chromes: Self.chromes()).test { client in
            let response = try await client.send(.get, "/devices/U/definition.json?chrome=iPhone%2017%20Pro")

            #expect(response.status == .ok)
        }
    }

    @Test func `should ask for a chrome when the device's model has none`() async throws {
        try await InProcessServer(chromes: Self.chromes(nil)).test { client in
            let response = try await client.send(.get, "/devices/U/definition.json")

            #expect(response.status == .notFound)
            #expect(response.json["needsChrome"] as? Bool == true)
            #expect(await client.status(.get, "/devices/ghost/definition.json") == .notFound)
        }
    }

    @Test func `should serve the merged bezel by default and the bare one when buttons is false`() async throws {
        try await InProcessServer(chromes: Self.chromes()).test { client in
            let merged = try await client.send(.get, "/devices/U/bezel.png")
            let bare = try await client.send(.get, "/simulators/U/bezel.png?buttons=false&panel=primary")

            #expect(merged.text == "MERGED-PNG")
            #expect(bare.text == "BARE-PNG")
        }
    }

    @Test func `should serve a chrome button's image and nothing for an unknown one`() async throws {
        try await InProcessServer(chromes: Self.chromes()).test { client in
            let power = try await client.send(.get, "/devices/U/chrome-button/power.png")

            #expect(power.text == "POWER-PNG")
            #expect(await client.status(.get, "/simulators/U/chrome-button/volume.png") == .notFound)
        }
    }

    @Test func `should serve the screen mask only when the chrome carries one`() async throws {
        let mask = ChromeImage(data: Data("MASK".utf8), size: Size(width: 1, height: 1))
        try await InProcessServer(chromes: Self.chromes(Self.assets(mask: mask))).test { client in
            let response = try await client.send(.get, "/devices/U/screen-mask.png")

            #expect(response.status == .ok)
        }
        try await InProcessServer(chromes: Self.chromes()).test { client in
            #expect(await client.status(.get, "/devices/U/screen-mask.png") == .notFound)
        }
    }

    @Test func `should serve a borrowed bezel's images by the chrome's name`() async throws {
        try await InProcessServer(chromes: Self.chromes()).test { client in
            let bezel = try await client.send(.get, "/devices/U/chrome/iPhone%2017%20Pro/bezel.png")
            let bare = try await client.send(.get, "/devices/U/chrome/iPhone%2017%20Pro/bezel.png?buttons=false")
            let button = try await client.send(.get, "/devices/U/chrome/iPhone%2017%20Pro/chrome-button/power.png")

            #expect(bezel.text == "MERGED-PNG")
            #expect(bare.text == "BARE-PNG")
            #expect(button.text == "POWER-PNG")
            #expect(await client.status(.get, "/devices/U/chrome/iPhone%2017%20Pro/screen-mask.png") == .notFound)
        }
    }

    @Test func `should serve nothing for a borrowed chrome that isn't installed`() async throws {
        try await InProcessServer(chromes: Self.chromes(nil)).test { client in
            #expect(await client.status(.get, "/devices/U/chrome/Nope/bezel.png") == .notFound)
            #expect(await client.status(.get, "/devices/U/chrome/Nope/chrome-button/power.png") == .notFound)
        }
    }

    // MARK: - stills

    @Test func `should capture a still of the device's screen in either format under both trees`() async throws {
        let devices = routeDevices { $0.register(.screen) { Self.screen() } }

        try await InProcessServer(devices: devices).test { client in
            for path in bothTrees("screenshot.png") + bothTrees("screenshot.jpg") {
                let response = try await client.send(.get, path)

                #expect(response.status == .ok, "\(path)")
                #expect(response.body.readableBytes > 0, "\(path)")
            }
        }
    }

    @Test func `should refuse a still with a capture option it can't read`() async throws {
        let devices = routeDevices { $0.register(.screen) { Self.screen() } }

        try await InProcessServer(devices: devices, chromes: Self.chromes()).test { client in
            #expect(await client.status(.get, "/devices/U/screenshot.png?size=huge") == .badRequest)
            #expect(await client.status(.get, "/devices/U/screenshot-bezel.png?size=huge") == .badRequest)
        }
    }

    @Test func `should refuse a still of a device with no screen, not running, or unknown`() async throws {
        try await InProcessServer().test { client in
            #expect(await client.status(.get, "/devices/U/screenshot.png") == .unprocessableContent)
            #expect(await client.status(.get, "/devices/ghost/screenshot.jpg") == .notFound)
            #expect(await client.status(.get, "/devices/U/screenshot-bezel.png") == .unprocessableContent)
            #expect(await client.status(.get, "/devices/ghost/screenshot-bezel.png") == .notFound)
        }
        let off = routeDevices(state: .off) { $0.register(.screen) { Self.screen() } }
        try await InProcessServer(devices: off).test { client in
            #expect(await client.status(.get, "/devices/U/screenshot.png") == .conflict)
        }
    }

    @Test func `should composite a still into the device's bezel`() async throws {
        let devices = routeDevices { $0.register(.screen) { Self.screen() } }
        let assets = DeviceChromeAssets(
            chrome: DeviceChrome(
                identifier: "phone", screenInsets: Insets(top: 10, left: 10, bottom: 10, right: 10),
                outerCornerRadius: 0, buttons: [], compositeImageName: "C"),
            composite: ChromeImage(data: Self.png(width: 60, height: 100), size: Size(width: 60, height: 100)),
            bareComposite: ChromeImage(data: Self.png(width: 60, height: 100), size: Size(width: 60, height: 100)),
            buttonImages: [:]
        )

        try await InProcessServer(devices: devices, chromes: Self.chromes(assets)).test { client in
            let response = try await client.send(.get, "/devices/U/screenshot-bezel.png?buttons=false")

            #expect(response.status == .ok)
            #expect(response.headers[.contentType] == "image/png")
        }
    }

    @Test func `should composite a still into the bezel the page picked when the device has none of its own`() async throws {
        let devices = routeDevices { $0.register(.screen) { Self.screen() } }
        let picked = DeviceChromeAssets(
            chrome: DeviceChrome(
                identifier: "iMac 27-inch", screenInsets: Insets(top: 10, left: 10, bottom: 30, right: 10),
                outerCornerRadius: 0, buttons: [], compositeImageName: nil),
            composite: ChromeImage(data: Self.png(width: 80, height: 70), size: Size(width: 80, height: 70)))
        let chromes = MockChromes()
        given(chromes).panels(forDeviceName: .any).willReturn([])
        given(chromes).assets(forDeviceName: .any).willProduce { $0 == "iMac 27-inch" ? picked : nil }
        given(chromes).assets(forDeviceName: .any, panel: .any).willProduce { name, _ in name == "iMac 27-inch" ? picked : nil }

        try await InProcessServer(devices: devices, chromes: chromes).test { client in
            let response = try await client.send(.get, "/devices/U/screenshot-bezel.png?chrome=iMac%2027-inch")

            #expect(response.status == .ok)
            let image = try #require(CGImageSourceCreateWithData(Data(buffer: response.body) as CFData, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            #expect(image.width == 80)
            #expect(image.height == 70)
            #expect(await client.status(.get, "/devices/U/screenshot-bezel.png") == .notFound)
        }
    }

    @Test func `should answer no bezel still for a device with no chrome or a screen that fails`() async throws {
        let devices = routeDevices { $0.register(.screen) { Self.screen() } }
        try await InProcessServer(devices: devices, chromes: Self.chromes(nil)).test { client in
            #expect(await client.status(.get, "/devices/U/screenshot-bezel.png") == .notFound)
        }
        let failing = routeDevices { $0.register(.screen) { Self.failingScreen() } }
        try await InProcessServer(devices: failing, chromes: Self.chromes()).test { client in
            #expect(await client.status(.get, "/devices/U/screenshot-bezel.png") == .internalServerError)
            #expect(await client.status(.get, "/devices/U/screenshot.png") == .internalServerError)
        }
    }

    // MARK: - 3D

    private static let installed = InstalledDeviceModel(
        definition: DeviceModelDefinition(
            schemaVersion: 1, id: "iphone", displayName: "iPhone",
            matches: DeviceModelMatches(),
            asset: DeviceModelAsset(file: "device.usdz", downloadURL: nil, sha256: nil),
            scene: DeviceModelScene(
                rootNode: "Device", screenNode: "Screen", screenMaterial: "Screen",
                nativeOrientation: .portrait,
                textureSize: RenderDimensions(width: 100, height: 200),
                usesScreenOverlay: false),
            variantSets: [
                DeviceVariantSet(
                    id: "finish", displayName: "Finish", primPath: "/Device", usdName: "Color",
                    default: "black",
                    choices: [DeviceVariantChoice(id: "black", displayName: "Black",
                                                  usdValue: "Black", previewColor: "#000000")]),
            ]),
        directoryURL: URL(fileURLWithPath: "/models/iphone"))

    private static func models(_ installed: InstalledDeviceModel?) -> MockDeviceModels {
        let models = MockDeviceModels()
        given(models).match(deviceType: .any, deviceName: .any).willReturn(installed)
        given(models).all().willReturn(installed.map { [$0] } ?? [])
        return models
    }

    @Test func `should describe the device's 3D model and its choices`() async throws {
        try await InProcessServer(models: Self.models(Self.installed)).test { client in
            for path in bothTrees("3d-model.json") {
                let response = try await client.send(.get, path)

                #expect(response.status == .ok, "\(path)")
                #expect(response.json["id"] as? String == "iphone", "\(path)")
            }
        }
    }

    @Test func `should describe no 3D model for a simulator with none or an unknown device`() async throws {
        try await InProcessServer(models: Self.models(nil)).test { client in
            #expect(await client.status(.get, "/devices/U/3d-model.json") == .notFound)
            #expect(await client.status(.get, "/devices/ghost/3d-model.json") == .notFound)
        }
    }

    @Test func `should render the device's 3D model around a still of its screen`() async throws {
        let renderer = MockDeviceRenderer()
        given(renderer).render(plan: .any, screenImage: .any).willReturn(Data("RENDERED".utf8))
        let devices = routeDevices { $0.register(.screen) { Self.screen() } }

        try await InProcessServer(devices: devices, models: Self.models(Self.installed), deviceRenderer: renderer)
            .test { client in
                for path in bothTrees("render-3d.png") {
                    let response = try await client.send(.post, path, body: "{}")

                    #expect(response.status == .ok, "\(path)")
                    #expect(response.text == "RENDERED", "\(path)")
                }
            }
    }

    @Test func `should answer each way a 3D render can fail on its status`() async throws {
        let failingRenderer = MockDeviceRenderer()
        given(failingRenderer).render(plan: .any, screenImage: .any).willThrow(RoleFailed())
        let devices = routeDevices { $0.register(.screen) { Self.screen() } }

        try await InProcessServer(devices: devices, models: Self.models(Self.installed),
                                  deviceRenderer: failingRenderer).test { client in
            #expect(await client.status(.post, "/devices/U/render-3d.png", body: "{}") == .internalServerError)
            #expect(await client.status(.post, "/devices/U/render-3d.png", body: "[") == .badRequest)
            #expect(await client.status(.post, "/devices/U/render-3d.png",
                                        body: #"{"variants":{"finish":"gold"}}"#) == .badRequest)
        }
        try await InProcessServer(devices: devices, models: Self.models(nil)).test { client in
            #expect(await client.status(.post, "/devices/U/render-3d.png", body: "{}") == .notFound)
        }
        let failing = routeDevices { $0.register(.screen) { Self.failingScreen() } }
        try await InProcessServer(devices: failing, models: Self.models(Self.installed)).test { client in
            #expect(await client.status(.post, "/devices/U/render-3d.png", body: "{}") == .internalServerError)
        }
        try await InProcessServer().test { client in
            #expect(await client.status(.post, "/devices/U/render-3d.png", body: "{}") == .unprocessableContent)
            #expect(await client.status(.post, "/devices/ghost/render-3d.png", body: "{}") == .notFound)
        }
    }

    private static func png(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        _ = CGImageDestinationFinalize(destination)
        return out as Data
    }
}

/// The pages, lists and static assets the router serves.
@Suite("Serve router: pages and lists")
struct PageRouterTests {

    @Test func `should send the bare root to the simulator list`() async throws {
        try await InProcessServer().test { client in
            let response = try await client.send(.get, "/")

            #expect(response.status == .found)
            #expect(response.headers[.location] == "/simulators")
        }
    }

    @Test func `should serve the one page for the list, a simulator, a device and the farm`() async throws {
        try await InProcessServer().test { client in
            for path in ["/simulators", "/simulators/U", "/devices/U", "/farm"] {
                let response = try await client.send(.get, path)

                // Whatever the web root holds here: the source tree isn't
                // reachable from every test binary.
                #expect(response.status == Server.staticAsset(path == "/farm" ? "farm/farm.html" : "sim.html").status,
                        "\(path)")
                #expect(response.header("Content-Security-Policy") == "frame-ancestors 'none'", "\(path)")
            }
        }
    }

    @Test func `should serve a web asset at the root and in a known subfolder, and nothing that isn't there`() async throws {
        try await InProcessServer().test { client in
            #expect(await client.status(.get, "/sim-list.js") == Server.staticAsset("sim-list.js").status)
            #expect(await client.status(.get, "/farm/farm.html") == Server.staticAsset("farm/farm.html").status)
            #expect(await client.status(.get, "/no-such-asset.js") == .notFound)
        }
    }

    @Test func `should list every device, simulators beside real ones`() async throws {
        try await InProcessServer().test { client in
            let response = try await client.send(.get, "/devices.json")

            #expect(response.status == .ok)
            #expect(response.text == #"""
                {"devices":[{"abilities":[],"id":"U",\#
                "kind":{"model":"iPhone 17","platform":"iOS","reality":"simulated"},\#
                "name":"iPhone 17","state":"ready"}]}
                """#)
        }
    }
}
