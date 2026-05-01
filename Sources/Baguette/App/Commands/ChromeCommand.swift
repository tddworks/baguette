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
            let chromes = defaultChromes()
            guard let json = try target
                .resolveAssets(in: chromes)?
                .layoutJSON() else {
                throw ChromeCommandError.notFound(target: target.label)
            }
            print(json)
        }
    }

    struct Composite: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "composite",
            abstract: "Write the rasterized composite bezel PNG to stdout"
        )

        @OptionGroup var target: ChromeTarget

        func run() throws {
            let chromes = defaultChromes()
            guard let png = try target
                .resolveAssets(in: chromes)?
                .composite.data else {
                throw ChromeCommandError.notFound(target: target.label)
            }
            FileHandle.standardOutput.write(png)
        }
    }
}

/// Either-or device targeting shared by `layout` and `composite`.
/// `--udid` goes through CoreSimulators (so the rich-domain
/// `simulator.chrome(in:)` does the work); `--device-name` skips
/// CoreSimulators entirely — useful for testing chrome reads on a
/// machine that doesn't have a booted device set.
struct ChromeTarget: ParsableArguments {
    @Option(name: .long, help: "Simulator UDID (resolved via CoreSimulator)")
    var udid: String?

    @Option(name: .long, help: "Device-type name, e.g. \"iPhone 17 Pro\"")
    var deviceName: String?

    @Option(name: .long, help: "Custom device set path (with --udid)")
    var deviceSet: String?

    /// Shown in error messages — whichever target the user supplied.
    var label: String {
        if let udid { return "udid \(udid)" }
        if let deviceName { return "\"\(deviceName)\"" }
        return "(none)"
    }

    func resolveAssets(in chromes: any Chromes) throws -> DeviceChromeAssets? {
        if let deviceName {
            return chromes.assets(forDeviceName: deviceName)
        }
        if let udid {
            let simulators = CoreSimulators(deviceSetPath: deviceSet)
            guard let sim = simulators.find(udid: udid) else {
                throw ChromeCommandError.simulatorNotFound(udid: udid)
            }
            return sim.chrome(in: chromes)
        }
        throw ChromeCommandError.missingTarget
    }
}

/// Production wiring — used by both subcommands. Behind a free
/// function so changing the wiring (e.g. adding a custom DeviceKit
/// search path) lands in one place.
private func defaultChromes() -> any Chromes {
    LiveChromes(
        store: FileSystemChromeStore(),
        rasterizer: CoreGraphicsPDFRasterizer()
    )
}

enum ChromeCommandError: Error, CustomStringConvertible {
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
