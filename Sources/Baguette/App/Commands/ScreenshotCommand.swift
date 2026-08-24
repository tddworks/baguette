import ArgumentParser
import Foundation

/// `baguette screenshot --udid <UDID> [--output path] [--quality N]
/// [--scale N] [--size SPEC] [--fit contain|cover|stretch]
/// [--background transparent|#RRGGBB] [--format png|jpg]`
///
/// Captures one frame from the simulator's framebuffer. Mirrors the
/// `GET /simulators/<UDID>/screenshot.jpg` endpoint so the same helper
/// drives both, and writes to `--output` (or stdout when omitted, so it
/// composes with shell redirection).
///
/// `--size` speaks the shared capture-size vocabulary — the same preset
/// ids the toolbar picker and the recorder use, so "App Store 6.9″"
/// means the same pixels wherever you ask for it. See
/// `docs/features/capture-size.md`.
struct ScreenshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture one frame from a simulator's screen"
    )

    @OptionGroup var options: DeviceOption

    @Option(name: .shortAndLong, help: "Output file (defaults to stdout)")
    var output: String?

    @Option(help: "JPEG quality (0.0 – 1.0); ignored for PNG")
    var quality: Double = 0.85

    @Option(help: "Integer downscale divisor (1 = native)")
    var scale: Int = 1

    @Option(help: ArgumentHelp(
        "Output size: WIDTHxHEIGHT, W:H, or one of: \(CaptureSize.presetList)"
    ))
    var size: String = "native"

    @Option(help: "How the frame fills the size: \(CaptureFit.allCases.map(\.rawValue).joined(separator: ", "))")
    var fit: String = CaptureFit.contain.rawValue

    // `#ffffff`, not `transparent`, so the CLI and the toolbar picker
    // agree — `Resources/Web/capture/capture-settings.js` defaults to
    // white too. At `native` size nothing is letterboxed, so the default
    // still never paints; it only matters once a size is asked for, and
    // there a JPEG (which has no alpha) would otherwise flatten the bars
    // to black. Pass `--background transparent` for a PNG with clear bars.
    @Option(help: "Letterbox background: transparent or #RRGGBB")
    var background: String = "#ffffff"

    @Option(help: "Image format: \(CaptureFormat.list) (defaults to the --output extension, else jpg)")
    var format: String?

    /// Which framebuffer plane to capture: `phone` (default) or
    /// `carplay`. CarPlay enables the external display first and fails
    /// closed when no framebuffer sits behind it.
    @Option(help: "Target display plane: phone | carplay")
    var display: String?

    /// Reject what the pipeline can't honour — and normalise the rest,
    /// so validation is exactly as forgiving as the parsers behind it.
    /// `CaptureSize.parse` is already case-insensitive; `--fit` and
    /// `--background` are trimmed and lowercased here so they are too.
    mutating func validate() throws {
        do {
            _ = try StreamDisplayPlan.from(cliFlag: display)
        } catch let error as DisplayFlagError {
            throw ValidationError(error.message)
        }

        do {
            _ = try CaptureSize.parse(size)
        } catch let error as CaptureSizeError {
            throw ValidationError(error.message)
        }

        fit = fit.trimmingCharacters(in: .whitespaces).lowercased()
        guard CaptureFit(rawValue: fit) != nil else {
            throw ValidationError(
                "--fit must be one of: \(CaptureFit.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }

        if let format, CaptureFormat(argument: format) == nil {
            throw ValidationError("--format must be one of: \(CaptureFormat.list)")
        }

        background = background.trimmingCharacters(in: .whitespaces).lowercased()
        if CaptureCanvas.background(background) != nil {
            let pattern = #"^#?[0-9a-f]{6}$"#
            guard background.range(of: pattern, options: .regularExpression) != nil else {
                throw ValidationError("--background must be transparent or #RRGGBB")
            }
        }
    }

    func run() async throws {
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            throw ExitCode.failure
        }
        // CarPlay plans enable the panel and fail closed on an unbound
        // plane; phone plans take the legacy screen untouched.
        let plan = try StreamDisplayPlan.from(cliFlag: display)
        let bound: (screen: any Screen, input: any Input)
        do {
            bound = try plan.bind(to: simulator)
        } catch let error as FramebufferSelectionError {
            // Otherwise this surfaces as its own enum dump, which names
            // the failure but not the remedy.
            log(error.message)
            throw ExitCode.failure
        }
        let bytes = try await ScreenSnapshot.capture(
            screen: bound.screen,
            quality: quality,
            scale: max(1, scale),
            size: try CaptureSize.parse(size),
            fit: CaptureFit(rawValue: fit) ?? .contain,
            background: background,
            format: CaptureFormat.resolve(
                explicit: format.flatMap(CaptureFormat.init(argument:)),
                output: output
            )
        )
        if let output {
            try bytes.write(to: URL(fileURLWithPath: output))
        } else {
            try FileHandle.standardOutput.write(contentsOf: bytes)
        }
    }
}
