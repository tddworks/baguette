import BaguetteDevice
import ArgumentParser
import Foundation

/// `baguette clipboard <get|sync|copy> --udid <UDID>`
///
/// The simulator's pasteboard as a resource: `get` prints its text
/// contents; `sync` copies the host Mac's pasteboard onto the
/// simulator full-fidelity — every representation, images included —
/// which is the path for pasting non-text content; `copy` is its
/// mirror, copying the simulator's pasteboard onto the host Mac's
/// clipboard (again full-fidelity), the path for pulling what the
/// simulator copied back onto the Mac. Backed by
/// `xcrun simctl pbpaste | pbsync`; to *put text on* the pasteboard
/// use `baguette paste` (optionally `--no-press`).
struct ClipboardCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clipboard",
        abstract: "Read the simulator's pasteboard, or sync it to/from the host",
        subcommands: [Get.self, Sync.self, Copy.self]
    )

    /// `baguette clipboard get --udid <UDID>`
    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get",
            abstract: "Print the simulator's pasteboard text to stdout"
        )

        @OptionGroup var options: DeviceOption

        func run() async throws {
            let device = try options.device()
            let pasteboard = try orExit { try device.require(.pasteboard) }
            do {
                // Raw, no trailing newline — mirrors `pbpaste` so the
                // output pipes byte-faithfully.
                CommandOutput.current.write(Data(try await pasteboard.text().utf8))
            } catch {
                tell("clipboard get failed: \(error)")
                throw ExitCode.failure
            }
        }
    }

    /// `baguette clipboard sync --udid <UDID>`
    struct Sync: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sync",
            abstract: "Copy the host Mac's pasteboard onto the simulator (images included)"
        )

        @OptionGroup var options: DeviceOption

        func run() async throws {
            let device = try options.device()
            let pasteboard = try orExit { try device.require(.pasteboard) }
            do {
                try await pasteboard.syncFromHost()
            } catch {
                tell("clipboard sync failed: \(error)")
                throw ExitCode.failure
            }
            tell("Synced host pasteboard onto \(device.name)")
        }
    }

    /// `baguette clipboard copy --udid <UDID>`
    struct Copy: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "copy",
            abstract: "Copy the simulator's pasteboard onto the host Mac (images included)"
        )

        @OptionGroup var options: DeviceOption

        func run() async throws {
            let device = try options.device()
            let pasteboard = try orExit { try device.require(.pasteboard) }
            do {
                try await pasteboard.syncToHost()
            } catch {
                tell("clipboard copy failed: \(error)")
                throw ExitCode.failure
            }
            tell("Copied \(device.name) pasteboard onto the host")
        }
    }
}
