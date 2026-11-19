import Foundation

public struct DeviceRotation: Equatable, Sendable, Codable {
    public let x: Double
    public let y: Double
    public let z: Double

    public static let zero = DeviceRotation(x: 0, y: 0, z: 0)

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public enum ScreenRotation: Int, CaseIterable, Sendable {
    case none = 0
    case quarter = 90
    case half = 180
    case threeQuarters = 270

    public var swapsDimensions: Bool { self == .quarter || self == .threeQuarters }

    /// The counterclockwise turn from an upright capture taken in
    /// `orientation` back to its panel's own buffer: a quarter turn per
    /// step of the interface cycle from portrait, on either panel.
    public init(capturedIn orientation: DeviceOrientation?) {
        switch orientation {
        case .landscapeLeft?: self = .quarter
        case .portraitUpsideDown?: self = .half
        case .landscapeRight?: self = .threeQuarters
        case .portrait?, nil: self = .none
        }
    }
}

public enum DeviceScreenFit: String, Equatable, Sendable, Codable {
    case cover
    case contain
    case stretch
}

public enum DeviceRenderBackground: Equatable, Sendable {
    case transparent
    case color(String)
}

public struct DeviceRenderPlan: Equatable, Sendable {
    public let model: InstalledDeviceModel
    public let variants: [DeviceVariantSelection]
    public let rotation: DeviceRotation
    public let outputSize: RenderDimensions
    public let fit: DeviceScreenFit
    public let background: DeviceRenderBackground
    /// Composite a reflective cover-glass layer over the screen. Off by
    /// default so automation screenshots stay pixel-stable.
    public let screenGlass: Bool
    public let hingeDegrees: Double?
    /// The interface orientation a saved capture was taken in. With it the
    /// image turns back to its panel's buffer and `rotation` includes the
    /// roll that stands the capture upright; without it neither happens.
    public let screenOrientation: DeviceOrientation?

    public var screenPanel: IntegratedPanel? {
        hingeDegrees.map { HingeAngle(degrees: $0).litPanel }
    }

    public var screenRotation: ScreenRotation {
        ScreenRotation(capturedIn: screenOrientation)
    }

    /// The glass layer is shaped for the inner screen and is left out when
    /// a pose lights the cover, where it would float beside the shut book.
    public var rendersScreenGlass: Bool {
        screenGlass && screenPanel != .primary
    }

    public static func build(
        model: InstalledDeviceModel,
        variants: [String: String],
        rotation: DeviceRotation,
        outputSize: RenderDimensions,
        fit: DeviceScreenFit = .cover,
        background: DeviceRenderBackground = .transparent,
        screenGlass: Bool = false,
        hingeDegrees: Double? = nil,
        screenOrientation: DeviceOrientation? = nil
    ) throws -> DeviceRenderPlan {
        guard outputSize.width > 0, outputSize.height > 0 else {
            throw DeviceModelError.invalidOutputSize
        }
        guard rotation.x.isFinite, rotation.y.isFinite, rotation.z.isFinite else {
            throw DeviceModelError.invalidRotation
        }
        if let hingeDegrees {
            guard model.definition.scene.fold != nil else {
                throw DeviceModelError.modelCannotFold(model.definition.id.rawValue)
            }
            guard hingeDegrees.isFinite, (0...180).contains(hingeDegrees) else {
                throw DeviceModelError.invalidHingeAngle
            }
        }
        if case .color(let color) = background {
            let pattern = #"^#[0-9A-Fa-f]{6}$"#
            guard color.range(of: pattern, options: .regularExpression) != nil else {
                throw DeviceModelError.invalidBackground(color)
            }
        }
        // A foldable left at its rest pose lies flat, its inner screen lit;
        // a phone's one panel turns like a cover.
        let litPanel = model.definition.scene.fold == nil
            ? IntegratedPanel.primary
            : HingeAngle(degrees: hingeDegrees ?? 180).litPanel
        let roll = screenOrientation.map { InterfaceRoll.degrees($0, litPanel: litPanel) } ?? 0
        return DeviceRenderPlan(
            model: model,
            variants: try model.definition.resolveVariants(variants),
            rotation: DeviceRotation(x: rotation.x, y: rotation.y, z: rotation.z + roll),
            outputSize: outputSize,
            fit: fit,
            background: background,
            screenGlass: screenGlass,
            hingeDegrees: hingeDegrees,
            screenOrientation: screenOrientation
        )
    }

    public init(model: InstalledDeviceModel, variants: [DeviceVariantSelection], rotation: DeviceRotation, outputSize: RenderDimensions, fit: DeviceScreenFit, background: DeviceRenderBackground, screenGlass: Bool, hingeDegrees: Double?, screenOrientation: DeviceOrientation?) {
        self.model = model
        self.variants = variants
        self.rotation = rotation
        self.outputSize = outputSize
        self.fit = fit
        self.background = background
        self.screenGlass = screenGlass
        self.hingeDegrees = hingeDegrees
        self.screenOrientation = screenOrientation
    }
}
