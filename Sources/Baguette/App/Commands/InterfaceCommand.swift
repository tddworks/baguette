import BaguetteDevice
import ArgumentParser
import Foundation

/// `baguette interface <appearance|contrast|text-size> --udid <UDID> [<value>]`
///
/// Reads or sets the booted simulator's interface settings — light /
/// dark appearance, Increase Contrast, and content size (Dynamic Type).
/// Backed by `xcrun simctl ui` — a one-shot subprocess, not the
/// SimulatorHID gesture path.
///
/// Each leaf both reads and writes, mirroring `simctl ui` itself: pass a
/// value to set it, omit it to print the current one. There's no
/// separate `get` verb to remember, and a read on a device that isn't
/// booted prints `unknown` rather than failing.
///
/// The value domain lives in `Domain/Interface/`; the spawn is in
/// `Infrastructure/Interface/SimctlInterface.swift`.
struct InterfaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "interface",
        abstract: "Read or set appearance, contrast and text size",
        subcommands: [Appearance.self, Contrast.self, TextSize.self]
    )

    /// `baguette interface appearance --udid <UDID> [light|dark]`
    struct Appearance: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "appearance",
            abstract: "Read or set the light / dark appearance style"
        )

        @OptionGroup var options: DeviceOption

        @Argument(help: "light | dark — omit to read the current style")
        var value: InterfaceAppearance?

        func run() async throws {
            let interface = try InterfaceCommand.resolve(options)
            if let value {
                try await InterfaceCommand.apply(options) {
                    try await interface.setAppearance(value)
                }
            } else {
                print(try await interface.appearance().rawValue)
            }
        }
    }

    /// `baguette interface contrast --udid <UDID> [enabled|disabled]`
    struct Contrast: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "contrast",
            abstract: "Read or set Increase Contrast"
        )

        @OptionGroup var options: DeviceOption

        @Argument(help: "enabled | disabled — omit to read the current setting")
        var value: InterfaceContrast?

        func run() async throws {
            let interface = try InterfaceCommand.resolve(options)
            if let value {
                try await InterfaceCommand.apply(options) {
                    try await interface.setIncreaseContrast(value)
                }
            } else {
                print(try await interface.increaseContrast().rawValue)
            }
        }
    }

    /// `baguette interface text-size --udid <UDID> [<category>|increment|decrement]`
    struct TextSize: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "text-size",
            abstract: "Read or set the content size category (Dynamic Type)"
        )

        @OptionGroup var options: DeviceOption

        @Argument(help: """
            increment | decrement | a category \
            (\(ContentSize.settable.compactMap(\.argument).joined(separator: " | "))) \
            — omit to read the current one
            """)
        var value: ContentSizeChange?

        func run() async throws {
            let interface = try InterfaceCommand.resolve(options)
            if let value {
                try await InterfaceCommand.apply(options) {
                    try await interface.setContentSize(value)
                }
            } else {
                print(try await interface.contentSize().rawValue)
            }
        }
    }

    // MARK: - shared plumbing

    /// The device's interface handle, or a clean CLI failure when the
    /// udid names nothing.
    fileprivate static func resolve(_ options: DeviceOption) throws -> any Interface {
        let device = try options.device()
        let interface = try orExit { try device.require(.interface) }
        return interface
    }

    /// Run a setter, turning a thrown `InterfaceError` into a logged
    /// message + non-zero exit rather than a stack trace.
    fileprivate static func apply(
        _ options: DeviceOption, _ body: () async throws -> Void
    ) async throws {
        do {
            try await body()
        } catch {
            log("interface update failed: \(error)")
            throw ExitCode.failure
        }
    }
}

// MARK: - ArgumentParser conformances
//
// Kept in App so Domain stays free of ArgumentParser. Each rejects the
// read-only states (`unknown` / `unsupported`) at parse time, so
// `interface appearance unknown` fails with a usage error naming the
// values that work instead of spawning simctl to be told no.

extension InterfaceAppearance: ExpressibleByArgument {
    public init?(argument: String) {
        let parsed = InterfaceAppearance(output: argument)
        guard parsed.argument != nil else { return nil }
        self = parsed
    }

    public static var allValueStrings: [String] { allCases.compactMap(\.argument) }
}

extension InterfaceContrast: ExpressibleByArgument {
    public init?(argument: String) {
        let parsed = InterfaceContrast(output: argument)
        guard parsed.argument != nil else { return nil }
        self = parsed
    }

    public static var allValueStrings: [String] { allCases.compactMap(\.argument) }
}

extension ContentSizeChange: ExpressibleByArgument {
    public init?(argument: String) { self.init(wire: argument) }

    public static var allValueStrings: [String] {
        ["increment", "decrement"] + ContentSize.settable.compactMap(\.argument)
    }
}
