import BaguetteDevice
import Foundation

struct DeviceRenderOptions: Equatable, Sendable {
    let rotation: DeviceRotation
    let variants: [String: String]
    /// What the caller asked the render to come out at, in the vocabulary
    /// the toolbar picker and `--size` share. `.native` — the default —
    /// means "whatever the captured screen already is".
    let captureSize: CaptureSize
    /// How the screenshot sits on the device's screen mesh — a UV placement.
    /// Not `CaptureFit`, which places a source on a canvas; the two share
    /// case names and nothing else.
    let fit: DeviceScreenFit
    let background: DeviceRenderBackground
    let screenGlass: Bool

    /// The exact pixel size, when the caller named one. `nil` for `native`
    /// and for a ratio, both of which only mean something once there is a
    /// captured screen to measure against — those go through
    /// `outputSize(source:)`.
    var size: RenderDimensions? {
        guard case .fixed(let dimensions) = captureSize.kind else { return nil }
        return dimensions
    }

    /// The canvas this render should be produced on, given the screen that
    /// was actually captured. A ratio grows against that source rather than
    /// cropping it, so `square` on a tall phone yields a tall-side square
    /// with the device centred.
    func outputSize(source: RenderDimensions) -> RenderDimensions {
        captureSize.resolve(source: source)
    }

    /// Pixel-size spelling, kept for the callers that predate the shared
    /// size vocabulary. `nil` is `native`.
    init(
        rotation: DeviceRotation,
        variants: [String: String],
        size: RenderDimensions?,
        fit: DeviceScreenFit,
        background: DeviceRenderBackground,
        screenGlass: Bool
    ) {
        self.init(
            rotation: rotation,
            variants: variants,
            captureSize: size.map(Self.exact) ?? .native,
            fit: fit,
            background: background,
            screenGlass: screenGlass
        )
    }

    init(
        rotation: DeviceRotation,
        variants: [String: String],
        captureSize: CaptureSize,
        fit: DeviceScreenFit,
        background: DeviceRenderBackground,
        screenGlass: Bool
    ) {
        self.rotation = rotation
        self.variants = variants
        self.captureSize = captureSize
        self.fit = fit
        self.background = background
        self.screenGlass = screenGlass
    }

    static func parsing(json: Data) throws -> DeviceRenderOptions {
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: json)
        } catch {
            throw DeviceModelError.invalidRenderOptions
        }

        let rotation = DeviceRotation(
            x: wire.rotation?.x ?? 0,
            y: wire.rotation?.y ?? 0,
            z: wire.rotation?.z ?? 0
        )
        guard rotation.x.isFinite, rotation.y.isFinite, rotation.z.isFinite else {
            throw DeviceModelError.invalidRenderOptions
        }

        // `size` arrives either as the pixel object the browser has always
        // posted, or as a spec string in the shared vocabulary — the same
        // `appstore-6.9` / `square` / `3:2` names the CLI takes. Neither
        // form ever falls back to a nearby size: an unreadable spec is a
        // rejected request, exactly like an unknown model variant.
        let captureSize: CaptureSize
        switch wire.size {
        case .none:
            captureSize = .native
        case .exact(let dimensions):
            guard dimensions.width > 0, dimensions.height > 0 else {
                throw DeviceModelError.invalidRenderOptions
            }
            captureSize = Self.exact(dimensions)
        case .spec(let spec):
            do {
                captureSize = try CaptureSize.parse(spec)
            } catch {
                throw DeviceModelError.invalidRenderOptions
            }
        }

        guard let fit = DeviceScreenFit(rawValue: wire.fit ?? "cover") else {
            throw DeviceModelError.invalidRenderOptions
        }

        let background: DeviceRenderBackground
        let backgroundValue = wire.background ?? "transparent"
        if backgroundValue == "transparent" {
            background = .transparent
        } else {
            let pattern = #"^#[0-9A-Fa-f]{6}$"#
            guard backgroundValue.range(
                of: pattern,
                options: .regularExpression
            ) != nil else {
                throw DeviceModelError.invalidRenderOptions
            }
            background = .color(backgroundValue)
        }

        return DeviceRenderOptions(
            rotation: rotation,
            variants: wire.variants ?? [:],
            captureSize: captureSize,
            fit: fit,
            background: background,
            screenGlass: wire.screenGlass ?? false
        )
    }

    /// An explicit pixel size wearing the shared vocabulary's clothes —
    /// the same value `CaptureSize.parse("1200x900")` produces.
    private static func exact(_ dimensions: RenderDimensions) -> CaptureSize {
        CaptureSize(
            spec: "\(dimensions.width)x\(dimensions.height)",
            label: "\(dimensions.width) × \(dimensions.height)",
            kind: .fixed(dimensions)
        )
    }
}

private extension DeviceRenderOptions {
    struct Wire: Decodable {
        let rotation: Rotation?
        let variants: [String: String]?
        let size: Size?
        let fit: String?
        let background: String?
        let screenGlass: Bool?
    }

    struct Rotation: Decodable {
        let x: Double
        let y: Double
        let z: Double
    }

    /// Both spellings of `"size"`: the `{width, height}` object the browser
    /// has always posted, and a `"square"` / `"appstore-6.9"` spec string.
    enum Size: Decodable {
        case exact(RenderDimensions)
        case spec(String)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let spec = try? container.decode(String.self) {
                self = .spec(spec)
                return
            }
            let pixels = try container.decode(Pixels.self)
            self = .exact(
                RenderDimensions(width: pixels.width, height: pixels.height)
            )
        }

        private struct Pixels: Decodable {
            let width: Int
            let height: Int
        }
    }
}
