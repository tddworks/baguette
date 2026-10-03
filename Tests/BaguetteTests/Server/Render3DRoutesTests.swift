import Foundation
import Mockable
import Testing
@testable import Baguette

@Suite("Server 3D render routes")
struct Render3DRoutesTests {

    @Test func `render3D resolves simulator model and invokes renderer`() throws {
        let (simulators, simulator, models, installed) = Self.fixture()
        let renderer = MockDeviceRenderer()
        given(renderer).render(plan: .any, screenImage: .value(Data("SCREEN".utf8)))
            .willReturn(Data("PNG".utf8))

        let outcome = Server.render3D(
            udid: "U",
            options: DeviceRenderOptions(
                rotation: DeviceRotation(x: 1, y: 2, z: 3),
                variants: ["finish": "silver"],
                size: RenderDimensions(width: 800, height: 600),
                fit: .contain,
                background: .transparent,
                screenGlass: false
            ),
            screenImage: Data("SCREEN".utf8),
            sourceSize: RenderDimensions(width: 100, height: 200),
            simulators: simulators,
            models: models,
            renderer: renderer
        )

        #expect(outcome == .rendered(Data("PNG".utf8)))
        // The stable type name resolves the model; the visible name is never consulted.
        verify(models).match(
            deviceType: .value("iPhone 17 Pro"),
            deviceName: .value("iPhone 17 Pro")
        ).called(1)
        verify(models).match(
            deviceType: .value("iPhone 17 Pro"),
            deviceName: .value("Demo")
        ).called(0)
        verify(renderer).render(
            plan: .matching {
                $0.model == installed
                    && $0.outputSize == RenderDimensions(width: 800, height: 600)
                    && $0.variants.map(\.usdValue) == ["Silver"]
            },
            screenImage: .value(Data("SCREEN".utf8))
        ).called(1)
        _ = simulator
    }

    // A ratio has no pixel size of its own — it only means something once
    // there is a captured screen to grow against. The route has to ask the
    // options to resolve it, not read the `fixed`-only `size` and silently
    // fall back to the source.
    @Test func `render3D grows a ratio size against the captured screen`() throws {
        let (simulators, simulator, models, _) = Self.fixture()
        let renderer = MockDeviceRenderer()
        given(renderer).render(plan: .any, screenImage: .any)
            .willReturn(Data("PNG".utf8))

        _ = Server.render3D(
            udid: "U",
            options: DeviceRenderOptions(
                rotation: DeviceRotation(x: 0, y: 0, z: 0),
                variants: [:],
                captureSize: try CaptureSize.parse("square"),
                fit: .cover,
                background: .transparent,
                screenGlass: false
            ),
            screenImage: Data("SCREEN".utf8),
            sourceSize: RenderDimensions(width: 100, height: 200),
            simulators: simulators,
            models: models,
            renderer: renderer
        )

        verify(renderer).render(
            plan: .matching { $0.outputSize == RenderDimensions(width: 200, height: 200) },
            screenImage: .any
        ).called(1)
        _ = simulator
    }

    @Test func `render3D reports unknown simulator without consulting models`() {
        let simulators = MockSimulators()
        let models = MockDeviceModels()
        let renderer = MockDeviceRenderer()
        given(simulators).find(udid: .value("ghost")).willReturn(nil)

        let outcome = Server.render3D(
            udid: "ghost",
            options: Self.defaults,
            screenImage: Data(),
            sourceSize: RenderDimensions(width: 100, height: 200),
            simulators: simulators,
            models: models,
            renderer: renderer
        )

        #expect(outcome == .unknownDevice)
    }

    @Test func `model metadata exposes only public ids and choices`() throws {
        let (simulators, _, models, _) = Self.fixture()

        let json = try #require(Server.model3DJSONString(
            udid: "U",
            simulators: simulators,
            models: models
        ))
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        #expect(object["id"] as? String == "iphone")
        let sets = try #require(object["variantSets"] as? [[String: Any]])
        let firstSet = try #require(sets.first)
        #expect(firstSet["id"] as? String == "finish")
        let choices = try #require(firstSet["choices"] as? [[String: Any]])
        #expect(choices.compactMap { $0["id"] as? String } == ["black", "silver"])
        #expect(json.contains("primPath") == false)
        #expect(json.contains("usdName") == false)
        #expect(json.contains("usdValue") == false)
    }

    @Test func `live 3D connection resolves its simulator model and render plan`() throws {
        let (simulators, _, models, installed) = Self.fixture()
        let options = try Device3DStreamOptions.parse([
            "rotation": ["-8,18,0"],
            "variant": ["finish:silver"],
            "width": ["960"],
            "height": ["720"],
        ])

        let plan = try Server.live3DPlan(
            udid: "U",
            options: options,
            simulators: simulators,
            models: models
        )

        #expect(plan.model == installed)
        #expect(plan.outputSize == RenderDimensions(width: 960, height: 720))
        #expect(plan.variants.map(\.usdValue) == ["Silver"])
    }

    @Test func `live 3D connection rejects an unknown simulator`() throws {
        let simulators = MockSimulators()
        let models = MockDeviceModels()
        given(simulators).find(udid: .value("ghost")).willReturn(nil)

        #expect(throws: DeviceModelError.modelNotFound("ghost")) {
            _ = try Server.live3DPlan(
                udid: "ghost",
                options: .default,
                simulators: simulators,
                models: models
            )
        }
    }

    @Test func `live 3D route accepts both existing stream codecs`() {
        #expect(Server.live3DFormat(pathExtension: "mjpeg") == .mjpeg)
        #expect(Server.live3DFormat(pathExtension: "avcc") == .avcc)
        #expect(Server.live3DFormat(pathExtension: "png") == nil)
    }

    @Test func `live camera control mutates the scene without replacing its stream`() throws {
        let scene = MockDeviceScene()
        given(scene).update(camera: .any).willReturn()

        let handled = try Server.handleLive3DControl(
            line: #"{"type":"set_3d_camera","rotation":{"x":-8,"y":32,"z":0},"zoom":1.2}"#,
            scene: scene
        )

        #expect(handled)
        verify(scene).update(camera: .matching {
            $0.rotation == DeviceRotation(x: -8, y: 32, z: 0)
                && $0.zoom == 1.2
        }).called(1)
    }

    @Test func `screen quad encodes its four corners in TL TR BR BL order`() throws {
        let quad = ScreenQuad(
            topLeft: NormalizedPoint(u: 0.1, v: 0.2),
            topRight: NormalizedPoint(u: 0.9, v: 0.2),
            bottomRight: NormalizedPoint(u: 0.9, v: 0.8),
            bottomLeft: NormalizedPoint(u: 0.1, v: 0.8)
        )

        let json = try #require(Server.screenQuadJSON(quad))
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let corners = try #require(object["corners"] as? [[Double]])

        #expect(object["type"] as? String == "screen_quad")
        #expect(corners == [[0.1, 0.2], [0.9, 0.2], [0.9, 0.8], [0.1, 0.8]])
    }

    @Test func `a foldable's screen pieces each carry their corners and their part of the buffer`() throws {
        let quad = ScreenQuad(
            topLeft: NormalizedPoint(u: 0.1, v: 0.2),
            topRight: NormalizedPoint(u: 0.5, v: 0.2),
            bottomRight: NormalizedPoint(u: 0.5, v: 0.8),
            bottomLeft: NormalizedPoint(u: 0.1, v: 0.8)
        )
        let pieces = [ScreenPiece(quad: quad, u: 0...1, v: 0.5...1)]
        let buttons = [ScreenButtonMark(
            id: "power", at: NormalizedPoint(u: 0.9, v: 0.3), control: NormalizedPoint(u: 0.95, v: 0.3))]

        let json = try #require(Server.screenPiecesJSON(
            pieces, buttons: buttons, litPanel: .primary,
            pose: FoldablePose(hingeDegrees: 0)))
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let encoded = try #require(object["pieces"] as? [[String: Any]])

        #expect(object["type"] as? String == "screen_quad")
        #expect(encoded.count == 1)
        #expect(encoded[0]["corners"] as? [[Double]] == [[0.1, 0.2], [0.5, 0.2], [0.5, 0.8], [0.1, 0.8]])
        #expect(encoded[0]["u"] as? [Double] == [0, 1])
        #expect(encoded[0]["v"] as? [Double] == [0.5, 1])
        let marks = try #require(object["buttons"] as? [[String: Any]])
        #expect(marks[0]["id"] as? String == "power")
        #expect(marks[0]["at"] as? [Double] == [0.9, 0.3])
        #expect(marks[0]["control"] as? [Double] == [0.95, 0.3])
        #expect(object["litPanel"] as? String == "primary")
        let pose = try #require(object["pose"] as? [String: Any])
        #expect(pose["hingeDegrees"] as? Double == 0)
    }
}

private extension Render3DRoutesTests {
    static var defaults: DeviceRenderOptions {
        DeviceRenderOptions(
            rotation: .zero,
            variants: [:],
            size: nil,
            fit: .cover,
            background: .transparent,
            screenGlass: false
        )
    }

    static func fixture() -> (
        MockSimulators, MockSimulator, MockDeviceModels, InstalledDeviceModel
    ) {
        let installed = InstalledDeviceModel(
            definition: DeviceModelDefinition(
                schemaVersion: 1,
                id: "iphone",
                displayName: "iPhone",
                matches: DeviceModelMatches(),
                asset: DeviceModelAsset(file: "device.usdz", downloadURL: nil, sha256: nil),
                scene: DeviceModelScene(
                    rootNode: "Device",
                    screenNode: "Screen",
                    screenMaterial: "Screen",
                    nativeOrientation: .portrait,
                    textureSize: RenderDimensions(width: 100, height: 200),
                    usesScreenOverlay: false
                ),
                variantSets: [
                    DeviceVariantSet(
                        id: "finish",
                        displayName: "Finish",
                        primPath: "/Device",
                        usdName: "Color",
                        default: "black",
                        choices: [
                            DeviceVariantChoice(
                                id: "black", displayName: "Black",
                                usdValue: "Black", previewColor: "#000000"
                            ),
                            DeviceVariantChoice(
                                id: "silver", displayName: "Silver",
                                usdValue: "Silver", previewColor: "#cccccc"
                            ),
                        ]
                    )
                ]
            ),
            directoryURL: URL(fileURLWithPath: "/models/iphone")
        )
        let simulator = MockSimulator()
        given(simulator).deviceTypeName.willReturn("iPhone 17 Pro")
        given(simulator).name.willReturn("Demo")
        let simulators = MockSimulators()
        given(simulators).find(udid: .value("U")).willReturn(simulator)
        let models = MockDeviceModels()
        given(models).match(deviceType: .any, deviceName: .any).willReturn(installed)
        return (simulators, simulator, models, installed)
    }
}
