import Foundation
import ImageIO

/// One still of a device on its 3D model, and how it was posed.
public struct Device3DRender: Equatable, Sendable {
    public let png: Data
    /// The hinge's angle the model was posed at; nil for a device that
    /// doesn't fold, or a foldable whose hinge gave no reading.
    public let hingeDegrees: Double?
    /// The panel the picture is on; nil for a device that doesn't fold.
    public let litPanel: IntegratedPanel?

    public init(png: Data, hingeDegrees: Double?, litPanel: IntegratedPanel?) {
        self.png = png
        self.hingeDegrees = hingeDegrees
        self.litPanel = litPanel
    }
}

public extension Device {
    /// This device on its 3D model as it stands now, `screenImage` on its
    /// screen: a foldable posed at its hinge's angle, the picture on the
    /// panel it lights (`Hinge.litPanel`, which asks the device before the
    /// angle). The models and the renderer are the caller's — nothing here
    /// looks either up.
    func render3D(
        screenImage: Data,
        sourceSize: RenderDimensions,
        models: any DeviceModels,
        renderer: any DeviceRenderer,
        options: DeviceRenderOptions
    ) throws -> Device3DRender {
        guard let model = try model3D(in: models) else {
            throw DeviceModelError.noModelForDevice(kind.model)
        }
        let hinge = model.definition.scene.fold == nil ? nil : try? require(.hinge)
        let degrees = hinge?.angle()?.degrees
        let lit = hinge?.litPanel
        let plan = try DeviceRenderPlan.build(
            model: model,
            variants: options.variants,
            rotation: options.rotation,
            outputSize: options.outputSize(source: sourceSize),
            fit: options.fit,
            background: options.background,
            screenGlass: options.screenGlass,
            hingeDegrees: degrees,
            litPanel: lit
        )
        return Device3DRender(
            png: try renderer.render(plan: plan, screenImage: screenImage),
            hingeDegrees: degrees,
            litPanel: lit
        )
    }

    /// `render3D` with what the device's screen shows right now.
    func snapshot3D(
        models: any DeviceModels,
        renderer: any DeviceRenderer,
        options: DeviceRenderOptions
    ) async throws -> Device3DRender {
        let screenImage = try await ScreenSnapshot.capture(screen: try require(.screen), quality: 0.95)
        guard let sourceSize = RenderDimensions(image: screenImage) else {
            throw DeviceModelError.screenImageInvalid
        }
        return try render3D(
            screenImage: screenImage, sourceSize: sourceSize,
            models: models, renderer: renderer, options: options)
    }
}

public extension RenderDimensions {
    /// The pixel size of an encoded image; nil when it can't be read.
    init?(image: Data) {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        self.init(width: width, height: height)
    }
}
