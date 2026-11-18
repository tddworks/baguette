import BaguetteDevice
import ArgumentParser
import Foundation

/// `baguette chrome <subcommand>` — read DeviceKit chrome data for a
/// simulator device family. Two leaves: `layout` prints the JSON the
/// front end needs to position the screen overlay, `composite` writes
/// the rasterized PNG bezel to stdout.
///
/// The plugin shells out to these from its HTTP route handlers so
/// the chrome data lives in one place (Baguette) without forcing
/// the plugin to depend on Baguette's source.
///
/// Subcommands accept `--udid` *or* `--device-name`. UDID is what
/// the plugin holds; device-name is convenient for ad-hoc CLI use
/// (`baguette chrome layout --device-name "iPhone 17 Pro"`).
struct ChromeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chrome",
        abstract: "Read DeviceKit chrome (bezel) data for a simulator",
        subcommands: [Layout.self, Composite.self]
    )

    struct Layout: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "layout",
            abstract: "Print the chrome layout JSON for the named device"
        )

        @OptionGroup var target: ChromeTarget

        func run() throws {
            let chromes = ChromeCommand.chromes
            guard let json = try target
                .resolveAssets(in: chromes)?
                .layoutJSON() else {
                throw ChromeCommandError.notFound(target: target.label)
            }
            say(json)
        }
    }

    struct Composite: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "composite",
            abstract: "Write the rasterized composite bezel PNG to stdout"
        )

        @OptionGroup var target: ChromeTarget

        func run() throws {
            let chromes = ChromeCommand.chromes
            guard let png = try target
                .resolveAssets(in: chromes)?
                .composite.data else {
                throw ChromeCommandError.notFound(target: target.label)
            }
            CommandOutput.current.write(png)
        }
    }
}

/// Either-or device targeting shared by `layout` and `composite`.
/// `--udid` goes through every device family (so the rich-domain
/// `device.chrome(in:)` does the work); `--device-name` skips
/// the devices entirely — useful for testing chrome reads on a
/// machine that doesn't have a booted device set.
struct ChromeTarget: ParsableArguments {
    @Option(name: .long, help: "Simulator UDID (resolved via CoreSimulator)")
    var udid: String?

    @Option(name: .long, help: "Device-type name, e.g. \"iPhone 17 Pro\"")
    var deviceName: String?

    @Option(name: .long, help: "Custom device set path (with --udid)")
    var deviceSet: String?

    /// Which of a foldable's panels to describe. Left out, a `--udid`
    /// target follows the hinge (the lit panel) and a `--device-name`
    /// target is the cover. Naming one reads that panel's chrome
    /// regardless of pose — the way to get the open layout for a
    /// device that is folded right now.
    @Option(name: .long, help: "Panel of a foldable: cover | unfolded (default: the lit one)")
    var panel: IntegratedPanel?

    /// Shown in error messages — whichever target the user supplied.
    var label: String {
        if let udid { return "udid \(udid)" }
        if let deviceName { return "\"\(deviceName)\"" }
        return "(none)"
    }

    func resolveAssets(in chromes: any Chromes) throws -> DeviceChromeAssets? {
        if let deviceName {
            guard let panel else { return chromes.assets(forDeviceName: deviceName) }
            return chromes.assets(forDeviceName: deviceName, panel: panel)
        }
        if let udid {
            guard let device = try allDevices(deviceSet: deviceSet).find(id: DeviceID(udid)) else {
                throw ChromeCommandError.simulatorNotFound(udid: udid)
            }
            guard let panel else { return device.chrome(in: chromes) }
            return chromes.assets(forDeviceName: device.kind.model, panel: panel)
        }
        throw ChromeCommandError.missingTarget
    }
}

/// CLI spelling of a foldable's panels: `cover` is the primary, `unfolded`
/// the secondary. Parsed at the App layer only.
extension IntegratedPanel: ExpressibleByArgument {
    public init?(argument: String) {
        switch argument.lowercased() {
        case "cover", "primary": self = .primary
        case "unfolded", "secondary": self = .secondary
        default: return nil
        }
    }
}

extension ChromeCommand {
    /// The chrome both subcommands read: Xcode's DeviceKit bundles, unless
    /// a test stands in. One place, so changing the wiring (e.g. adding a
    /// custom DeviceKit search path) lands once.
    @TaskLocal static var chromes: any Chromes = LiveChromes(
        store: FileSystemChromeStore(),
        rasterizer: CoreGraphicsPDFRasterizer()
    )
}

enum ChromeCommandError: Error, Equatable, CustomStringConvertible {
    case missingTarget
    case simulatorNotFound(udid: String)
    case notFound(target: String)

    var description: String {
        switch self {
        case .missingTarget:
            return "expected --udid or --device-name"
        case .simulatorNotFound(let udid):
            return "no simulator with udid \(udid)"
        case .notFound(let target):
            return "no chrome bundle covers \(target)"
        }
    }
}
