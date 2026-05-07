import ArgumentParser
import Foundation

/// `baguette mac describe-ui --bundle-id <X> [--x <pt> --y <pt>]`
///
/// Dumps the macOS app's frontmost-window accessibility tree as
/// JSON. Frames are in **window-relative points** (top-left of
/// the window's content rect = (0, 0)), so the JSON aligns with
/// a window-cropped screenshot from `mac screenshot`.
///
/// Mirrors `baguette describe-ui` for symmetry with the iOS path.
struct MacDescribeUICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "describe-ui",
        abstract: "Dump a macOS app's accessibility tree as JSON"
    )

    @OptionGroup var target: MacAppOption

    @Option(help: "Hit-test x coordinate (window points). Pair with --y.")
    var x: Double?

    @Option(help: "Hit-test y coordinate (window points). Pair with --x.")
    var y: Double?

    @Option(name: .shortAndLong, help: "Output file (defaults to stdout)")
    var output: String?

    func run() async throws {
        let apps = RunningMacApps()
        guard let app = apps.find(bundleID: target.bundleId) else {
            log("App \(target.bundleId) not running")
            throw ExitCode.failure
        }
        let ax = app.accessibility()

        let result: AXNode?
        do {
            switch (x, y) {
            case let (px?, py?):
                result = try ax.describeAt(point: Point(x: px, y: py))
            case (nil, nil):
                result = try ax.describeAll()
            default:
                log("describe-ui: --x and --y must be supplied together")
                throw ExitCode.failure
            }
        } catch let error as MacAppError {
            switch error {
            case .tccDenied(scope: .accessibility):
                log("describe-ui: Accessibility permission required.")
                log("  Grant baguette in System Settings → Privacy & Security → Accessibility.")
            default:
                log("describe-ui: \(error)")
            }
            throw ExitCode.failure
        }

        guard let tree = result else {
            log("describe-ui: no accessibility data (app has no on-screen window?)")
            throw ExitCode.failure
        }
        let bytes = Data(tree.json.utf8)
        if let output {
            try bytes.write(to: URL(fileURLWithPath: output))
        } else {
            try FileHandle.standardOutput.write(contentsOf: bytes)
            try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
        }
    }
}
