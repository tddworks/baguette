import AppKit
import Foundation
import ImageIO
import Testing

@testable import Baguette
@testable import BaguetteDevice

@Suite("RealityKitDeviceRenderer")
struct RealityKitDeviceRendererTests {
    @Test func `should reject folding a single-panel device instead of dropping its screenshot`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        #expect(throws: DeviceModelError.modelCannotFold("test-device")) {
            _ = try Self.plan(directory: scratch, file: "device.usda", hingeDegrees: 30)
        }
    }

    /// The capture goes where the device shows it: the inner screen when
    /// open, the cover — turned by the fold to face the camera — when shut.
    @Test func `should land a saved capture on the cover when shut and on the inner screen when open`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let screen = try Self.screenPNG()
        let renderer = RealityKitDeviceRenderer()
        let open = try renderer.render(
            plan: Self.plan(directory: scratch, file: "foldable.usda", foldable: true, hingeDegrees: 180),
            screenImage: screen
        )
        let shut = try renderer.render(
            plan: Self.plan(directory: scratch, file: "foldable.usda", foldable: true, hingeDegrees: 0),
            screenImage: screen
        )
        let openBlue = try Self.bluePixels(open)
        let shutBlue = try Self.bluePixels(shut)
        #expect(openBlue > 200)
        // A capture left on the covered inner screen shows only as a sliver.
        #expect(shutBlue * 2 > openBlue)
        // Shut, the leaf lies over the right half, so the book is narrower.
        #expect(try Self.opaqueWidth(shut) * 4 < Self.opaqueWidth(open) * 3)
    }

    @Test func `should rotate an indexed PNG that already renders without rotation`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let plan = try Self.plan(directory: scratch, file: "device.usda")
        let palette: [UInt8] = [255, 0, 0, 0, 255, 0]
        let space = try #require(CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(),
            last: 1, colorTable: palette))
        // One red corner, so a half turn changes the image.
        let provider = try #require(CGDataProvider(data: Data([0, 1, 1, 1]) as CFData))
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8,
            bitsPerPixel: 8, bytesPerRow: 2, space: space, bitmapInfo: [],
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let renderer = RealityKitDeviceRenderer()
        _ = try renderer.render(plan: plan, screenImage: data as Data)
        // Upside down rolls the model a half turn and turns the image a half
        // turn; a model rolled alone must not look the same.
        let rolledOnly = try Self.plan(directory: scratch, file: "device.usda", rotation: DeviceRotation(x: -8, y: 18, z: 180))
        let upsideDown = try Self.plan(directory: scratch, file: "device.usda", screenOrientation: .portraitUpsideDown)
        let result = try renderer.render(plan: upsideDown, screenImage: data as Data)
        #expect(try Self.opaqueHeight(result) > 160)
        #expect(try result != renderer.render(plan: rolledOnly, screenImage: data as Data))
    }

    @Test func `should render a generated device scene at the requested PNG dimensions`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let plan = try Self.plan(directory: scratch, file: "device.usda")
        let screen = try Self.screenPNG()

        let png = try RealityKitDeviceRenderer().render(plan: plan, screenImage: screen)

        #expect(Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 320)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 240)
        #expect(try Self.opaqueHeight(png) > 160)
    }

    @Test func `should report the declared local asset when it is missing`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let plan = try Self.plan(directory: scratch, file: "missing.usdz")

        #expect(throws: DeviceModelError.localAssetNotFound("missing.usdz")) {
            _ = try RealityKitDeviceRenderer().render(
                plan: plan,
                screenImage: Data("not reached".utf8)
            )
        }
    }

    @Test func `should change the rendered device finish with a material appearance variant`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let orange = try Self.plan(
            directory: scratch, file: "device.usda", finish: "orange"
        )
        let blue = try Self.plan(
            directory: scratch, file: "device.usda", finish: "blue"
        )
        let screen = try Self.screenPNG()

        let orangePNG = try RealityKitDeviceRenderer().render(
            plan: orange, screenImage: screen
        )
        let bluePNG = try RealityKitDeviceRenderer().render(
            plan: blue, screenImage: screen
        )

        #expect(orangePNG != bluePNG)
    }
}

private extension RealityKitDeviceRendererTests {
    static func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "baguette-rk-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try RealityKitRenderFixtures.deviceUSDA.write(
            to: url.appending(path: "device.usda"),
            atomically: true,
            encoding: .utf8
        )
        try RealityKitRenderFixtures.foldableDeviceUSDA.write(
            to: url.appending(path: "foldable.usda"),
            atomically: true,
            encoding: .utf8
        )
        return url
    }

    static func screenPNG() throws -> Data {
        let image = NSImage(size: NSSize(width: 100, height: 200))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 100, height: 200)).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return png
    }

    /// RGBA bytes, rows top first.
    static func rgba(_ png: Data) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let imageSource = try #require(
            CGImageSourceCreateWithData(png as CFData, nil)
        )
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (pixels, width, height)
    }

    static func opaqueWidth(_ png: Data) throws -> Int {
        let (pixels, width, height) = try rgba(png)
        let occupied = (0..<width).filter { column in
            (0..<height).contains { row in pixels[(row * width + column) * 4 + 3] > 8 }
        }
        guard let first = occupied.first, let last = occupied.last else { return 0 }
        return last - first + 1
    }

    /// Opaque pixels showing `screenPNG()`'s blue.
    static func bluePixels(_ png: Data) throws -> Int {
        let (pixels, _, _) = try rgba(png)
        return stride(from: 0, to: pixels.count, by: 4).filter { index in
            pixels[index + 3] > 200 && pixels[index + 2] > 150 && pixels[index] < 90
        }.count
    }

    static func opaqueHeight(_ png: Data) throws -> Int {
        let (pixels, width, height) = try rgba(png)
        let occupiedRows = (0..<height).filter { row in
            (0..<width).contains { column in
                pixels[(row * width + column) * 4 + 3] > 8
            }
        }
        guard let first = occupiedRows.first, let last = occupiedRows.last else {
            return 0
        }
        return last - first + 1
    }

    static func plan(
        directory: URL,
        file: String,
        finish: String? = nil,
        foldable: Bool = false,
        hingeDegrees: Double? = nil,
        screenOrientation: DeviceOrientation? = nil,
        rotation: DeviceRotation = DeviceRotation(x: -8, y: 18, z: 0)
    ) throws -> DeviceRenderPlan {
        let model = InstalledDeviceModel(
            definition: DeviceModelDefinition(
                schemaVersion: 1,
                id: "test-device",
                displayName: "Test Device",
                matches: DeviceModelMatches(),
                asset: DeviceModelAsset(file: file, downloadURL: nil, sha256: nil),
                scene: DeviceModelScene(
                    rootNode: "Device",
                    screenNode: "Screen",
                    screenMaterial: "ScreenMaterial",
                    nativeOrientation: .portrait,
                    textureSize: RenderDimensions(width: 100, height: 200),
                    usesScreenOverlay: false,
                    fold: foldable ? DeviceModelFold(
                        clip: "default subtree animation", shutTime: 5, coverMaterial: "CoverMaterial",
                        coverTextureSize: RenderDimensions(width: 100, height: 200), openPoseDegrees: 130
                    ) : nil
                ),
                variantSets: finish == nil ? [] : [
                    DeviceVariantSet(
                        id: "finish",
                        displayName: "Finish",
                        primPath: "/Device",
                        usdName: "Finish",
                        default: "orange",
                        choices: [
                            DeviceVariantChoice(
                                id: "orange",
                                displayName: "Orange",
                                usdValue: "Orange",
                                previewColor: "#ff6600",
                                materialColors: ["DeviceBody": "#ff6600"]
                            ),
                            DeviceVariantChoice(
                                id: "blue",
                                displayName: "Blue",
                                usdValue: "Blue",
                                previewColor: "#334477",
                                materialColors: ["DeviceBody": "#334477"]
                            ),
                        ],
                        kind: .materials
                    ),
                ]
            ),
            directoryURL: directory
        )
        return try DeviceRenderPlan.build(
            model: model,
            variants: finish.map { ["finish": $0] } ?? [:],
            rotation: rotation,
            outputSize: RenderDimensions(width: 320, height: 240),
            hingeDegrees: hingeDegrees,
            screenOrientation: screenOrientation
        )
    }
}
