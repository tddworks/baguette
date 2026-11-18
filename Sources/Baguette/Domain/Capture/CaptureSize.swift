import BaguetteDevice
import Foundation

/// The output size a capture should come out at — the Swift half of the
/// vocabulary `Resources/Web/capture/capture-size.js` speaks in the
/// browser. `baguette screenshot --size appstore-6.9`, `?size=square` on
/// the HTTP routes, and the toolbar picker all resolve through the same
/// preset ids and the same placement maths, so a size means one thing
/// wherever the user says it.
///
/// Three flavours behind one interface:
///
/// - `native` — whatever the source already is; every plan is a no-op.
/// - `fixed` — an exact pixel size (the App Store submission sizes).
/// - `ratio` — an aspect ratio resolved against the source. A ratio
///   **never downscales**: it grows the binding axis so the source still
///   fits at 1:1. A 1290×2796 phone asked for `square` gets a 2796×2796
///   canvas, not a 1290×1290 crop — cropping a marketing shot to fit a
///   square is exactly what the user did *not* ask for.
struct CaptureSize: Equatable, Sendable {

    /// How a size is derived. Not a wire type — `spec` is what travels.
    enum Kind: Equatable, Sendable {
        case native
        case fixed(RenderDimensions)
        case ratio(Double)
    }

    /// Round-trips through `parse` — a preset name, `1920x1080`, or `3:2`.
    let spec: String
    /// Human label for the picker and `--help`.
    let label: String
    let kind: Kind

    // MARK: - Catalogue

    static let presets: [CaptureSize] = [
        CaptureSize(spec: "native", label: "Native", kind: .native),
        CaptureSize(
            spec: "appstore-6.9", label: "App Store 6.9\"",
            kind: .fixed(RenderDimensions(width: 1290, height: 2796))
        ),
        CaptureSize(
            spec: "appstore-6.5", label: "App Store 6.5\"",
            kind: .fixed(RenderDimensions(width: 1242, height: 2688))
        ),
        CaptureSize(
            spec: "appstore-ipad-13", label: "App Store iPad 13\"",
            kind: .fixed(RenderDimensions(width: 2064, height: 2752))
        ),
        CaptureSize(spec: "square", label: "Square", kind: .ratio(1)),
        CaptureSize(spec: "16:9", label: "Landscape 16:9", kind: .ratio(16.0 / 9.0)),
        CaptureSize(spec: "9:16", label: "Portrait 9:16", kind: .ratio(9.0 / 16.0)),
        CaptureSize(spec: "4:3", label: "Classic 4:3", kind: .ratio(4.0 / 3.0)),
        CaptureSize(spec: "4:5", label: "Social 4:5", kind: .ratio(4.0 / 5.0)),
    ]

    static let native = CaptureSize(spec: "native", label: "Native", kind: .native)

    /// One line listing every preset — for `--help` and error messages.
    static var presetList: String {
        presets.map(\.spec).joined(separator: " | ")
    }

    var isNative: Bool {
        kind == .native
    }

    // MARK: - Parsing

    /// A preset name (`square`), literal pixels (`1920x1080`), or a bare
    /// ratio (`3:2`). Anything else throws — baguette never substitutes a
    /// size the caller didn't ask for.
    static func parse(_ spec: String) throws -> CaptureSize {
        let text = spec.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { throw CaptureSizeError.unknownSize(spec) }

        if let preset = presets.first(where: { $0.spec == text }) {
            return preset
        }
        if let pair = split(text, on: "x"),
           pair.0 > 0, pair.1 > 0 {
            return CaptureSize(
                spec: "\(pair.0)x\(pair.1)",
                label: "\(pair.0) × \(pair.1)",
                kind: .fixed(RenderDimensions(width: pair.0, height: pair.1))
            )
        }
        if let pair = split(text, on: ":"), pair.0 > 0, pair.1 > 0 {
            return CaptureSize(
                spec: "\(pair.0):\(pair.1)",
                label: "\(pair.0):\(pair.1)",
                kind: .ratio(Double(pair.0) / Double(pair.1))
            )
        }
        throw CaptureSizeError.unknownSize(spec)
    }

    private static func split(_ text: String, on separator: Character) -> (Int, Int)? {
        let parts = text.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let first = Int(parts[0]),
              let second = Int(parts[1]) else { return nil }
        return (first, second)
    }

    // MARK: - Geometry

    /// The canvas dimensions this size wants for a given source.
    func resolve(source: RenderDimensions) -> RenderDimensions {
        switch kind {
        case .native:
            return source
        case .fixed(let dimensions):
            return dimensions
        case .ratio(let ratio):
            guard source.width > 0, source.height > 0, ratio > 0 else {
                return RenderDimensions(width: 0, height: 0)
            }
            // Grow the binding axis so the source still fits at 1:1.
            let sourceRatio = Double(source.width) / Double(source.height)
            if sourceRatio > ratio {
                return RenderDimensions(
                    width: source.width,
                    height: roundedHalfUp(Double(source.width) / ratio)
                )
            }
            return RenderDimensions(
                width: roundedHalfUp(Double(source.height) * ratio),
                height: source.height
            )
        }
    }

    /// Canvas size plus where the source lands inside it.
    func plan(source: RenderDimensions, fit: CaptureFit) -> CapturePlacement {
        let canvas = resolve(source: source)
        guard canvas.width > 0, canvas.height > 0,
              source.width > 0, source.height > 0 else {
            return CapturePlacement(
                width: max(0, canvas.width), height: max(0, canvas.height),
                drawX: 0, drawY: 0, drawWidth: 0, drawHeight: 0
            )
        }
        if isNative || fit == .stretch {
            return CapturePlacement(
                width: canvas.width, height: canvas.height,
                drawX: 0, drawY: 0, drawWidth: canvas.width, drawHeight: canvas.height
            )
        }
        let sx = Double(canvas.width) / Double(source.width)
        let sy = Double(canvas.height) / Double(source.height)
        let scale = fit == .cover ? max(sx, sy) : min(sx, sy)
        let drawWidth = roundedHalfUp(Double(source.width) * scale)
        let drawHeight = roundedHalfUp(Double(source.height) * scale)
        return CapturePlacement(
            width: canvas.width,
            height: canvas.height,
            drawX: roundedHalfUp(Double(canvas.width - drawWidth) / 2),
            drawY: roundedHalfUp(Double(canvas.height - drawHeight) / 2),
            drawWidth: drawWidth,
            drawHeight: drawHeight
        )
    }
}

/// How the source is placed when its aspect doesn't match the target.
enum CaptureFit: String, Equatable, Sendable, CaseIterable {
    /// Letterbox onto the background, preserving the whole source.
    case contain
    /// Fill the canvas, cropping whatever overflows.
    case cover
    /// Distort to fill exactly.
    case stretch
}

/// Rounds half UP, matching JavaScript's `Math.round`.
///
/// Swift's `Double.rounded()` rounds half *away from zero*, so the two
/// implementations of this vocabulary agree on positive halves and drift
/// by a pixel on negative ones — which is exactly `.cover`, the one case
/// where the draw origin goes negative. A frame has to land on the same
/// pixel whether it was placed by `capture-size.js` or by this file.
private func roundedHalfUp(_ value: Double) -> Int {
    Int((value + 0.5).rounded(.down))
}

/// Where a source lands inside a target canvas. `drawX` / `drawY` may be
/// negative under `.cover` — that overflow is the crop.
struct CapturePlacement: Equatable, Sendable {
    let width: Int
    let height: Int
    let drawX: Int
    let drawY: Int
    let drawWidth: Int
    let drawHeight: Int

    /// True when the placement is "leave the source exactly as it is" —
    /// callers skip the redraw entirely and keep the original bytes.
    func isIdentity(for source: RenderDimensions) -> Bool {
        drawX == 0 && drawY == 0
            && width == source.width && height == source.height
            && drawWidth == source.width && drawHeight == source.height
    }
}

enum CaptureSizeError: Error, Equatable {
    case unknownSize(String)

    var message: String {
        switch self {
        case .unknownSize(let spec):
            return "Unknown size '\(spec)'. Expected WIDTHxHEIGHT, W:H, "
                + "or one of: \(CaptureSize.presetList)"
        }
    }
}
