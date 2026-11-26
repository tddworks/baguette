import BaguetteDevice
import BaguetteDeviceFamilies
import ArgumentParser
import Foundation
import ImageIO

struct Render3DCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "render-3d",
        abstract: "Render a simulator screen on an installed 3D device model"
    )

    @Option(help: "Simulator UDID to capture")
    var udid: String?

    @Option(help: "Existing PNG or JPEG screen image")
    var screen: String?

    @Option(help: "Installed 3D model definition ID")
    var device: String?

    @Option(help: "With --screen: the interface orientation the capture was taken in, so it renders upright.")
    var screenOrientation: DeviceOrientation?

    @Option(help: "With --screen and a foldable model: fold angle, 0 through 180 degrees")
    var hingeDegrees: Double?

    @Option(help: "Custom CoreSimulator device-set path")
    var deviceSet: String?

    @Option(name: .customLong("variant"), help: "Model variant as SET=CHOICE (repeatable)")
    var variants: [String] = []

    @Option(help: "Device rotation as X,Y,Z degrees")
    var rotation: String = "0,0,0"

    // The shared capture vocabulary: a preset, literal pixels, or a bare
    // ratio. Omitted is `native` — the captured screen's own dimensions,
    // which is what --size has always defaulted to.
    @Option(help: """
    Output size: WIDTHxHEIGHT, W:H, or one of: \(CaptureSize.presetList) \
    (defaults to the captured screen size)
    """)
    var size: String?

    // `--fit` is NOT the canvas fit `CaptureFit` describes, despite the
    // shared case names: this is how the screenshot is laid onto the device's
    // screen mesh (a UV placement), while `--size` above governs the canvas
    // the whole render lands on. The two never meet.
    @Option(help: "Screen placement: cover, contain, or stretch")
    var fit: String = "cover"

    @Option(help: "Canvas background: transparent or #RRGGBB")
    var background: String = "transparent"

    @Flag(name: .customLong("screen-glass"),
          help: "Composite a reflective cover glass over the screen")
    var screenGlass: Bool = false

    @Option(name: .shortAndLong, help: "Output PNG file (defaults to stdout)")
    var output: String?

    mutating func validate() throws {
        guard (udid == nil) != (screen == nil) else {
            throw ValidationError("exactly one of --udid and --screen is required")
        }
        if screen != nil, device == nil {
            throw ValidationError("--device is required with --screen")
        }
        if screen == nil, hingeDegrees != nil || screenOrientation != nil {
            throw ValidationError("--hinge-degrees and --screen-orientation require --screen")
        }
        _ = try DeviceRenderArguments.rotation(rotation)
        if let size { _ = try DeviceRenderArguments.captureSize(size) }
        _ = try DeviceRenderArguments.variants(variants)
        guard DeviceScreenFit(rawValue: fit) != nil else {
            throw ValidationError("--fit must be cover, contain, or stretch")
        }
        if background != "transparent" {
            let pattern = #"^#[0-9A-Fa-f]{6}$"#
            guard background.range(of: pattern, options: .regularExpression) != nil else {
                throw ValidationError("--background must be transparent or #RRGGBB")
            }
        }
    }

    /// The 3D models a run reads and what draws them, when a test stands
    /// in; unset, the installed models and RealityKit.
    @TaskLocal static var models: (any DeviceModels)?
    @TaskLocal static var renderer: (any DeviceRenderer)?

    func run() async throws {
        let models = try Self.models ?? LiveDeviceModels(rootURLs: DeviceModelRoots.standard())
        let renderer = Self.renderer ?? RealityKitDeviceRenderer()
        let screenImage: Data
        let installed: InstalledDeviceModel

        if let screen {
            screenImage = try Data(contentsOf: URL(fileURLWithPath: screen))
            guard let device,
                  let found = try models.find(id: DeviceModelID(device)) else {
                throw DeviceModelError.modelNotFound(device ?? "")
            }
            installed = found
        } else if let udid {
            guard let simulator = try allDevices(deviceSet: deviceSet).find(id: DeviceID(udid)) else {
                throw SimulatorError.notFound(udid: udid)
            }
            if let device {
                guard let found = try models.find(id: DeviceModelID(device)) else {
                    throw DeviceModelError.modelNotFound(device)
                }
                installed = found
            } else {
                guard let found = try simulator.model3D(in: models) else {
                    throw DeviceModelError.noModelForDevice(simulator.kind.model)
                }
                installed = found
            }
            // The screen as it is, booted or not: the capture says why it failed.
            screenImage = try await ScreenSnapshot.capture(
                screen: try orExit { try simulator.abilities.require(.screen) },
                quality: 0.95
            )
        } else {
            throw ValidationError("exactly one of --udid and --screen is required")
        }

        // A ratio (`square`, `3:2`) has no meaning until there is a source
        // to grow against, and that source is the screenshot we just took —
        // the same image `native` would render at 1:1.
        let sourceSize = try Self.pixelSize(of: screenImage)
        let captureSize = try size.map(DeviceRenderArguments.captureSize) ?? .native
        let outputSize = captureSize.resolve(source: sourceSize)
        let plan = try DeviceRenderPlan.build(
            model: installed,
            variants: DeviceRenderArguments.variants(variants),
            rotation: DeviceRenderArguments.rotation(rotation),
            outputSize: outputSize,
            fit: DeviceScreenFit(rawValue: fit) ?? .cover,
            background: background == "transparent"
                ? .transparent
                : .color(background),
            screenGlass: screenGlass,
            hingeDegrees: hingeDegrees,
            screenOrientation: screenOrientation
        )
        let png = try renderer.render(plan: plan, screenImage: screenImage)
        if let output {
            try png.write(to: URL(fileURLWithPath: output), options: .atomic)
        } else {
            CommandOutput.current.write(png)
        }
    }

    private static func pixelSize(of image: Data) throws -> RenderDimensions {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source, 0, nil
              ) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw DeviceModelError.screenImageInvalid
        }
        return RenderDimensions(width: width, height: height)
    }
}
