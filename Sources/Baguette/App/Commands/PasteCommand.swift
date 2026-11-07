import ArgumentParser
import Foundation

/// `baguette paste --udid <UDID> --text "<text>" [--no-press]`
///
/// Sets the booted simulator's pasteboard to the given text (any
/// unicode — the path around `type`'s US-ASCII keystroke limit),
/// then presses Cmd+V so the frontmost app pastes it. `--no-press`
/// stops after the pasteboard set, for apps that read
/// `UIPasteboard` directly. The pasteboard ride is `xcrun simctl
/// pbcopy`; the keystroke rides the same HID path as `key`.
struct PasteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paste",
        abstract: "Paste text into the focused field via the simulator's pasteboard"
    )

    @OptionGroup var options: DeviceOption

    @Option(help: "Text to paste. Any unicode — emoji and accents included.")
    var text: String

    @Flag(inversion: .prefixedNo, help: "Whether to press Cmd+V after setting the pasteboard.")
    var press: Bool = true

    func run() async throws {
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            throw ExitCode.failure
        }
        let ok: Bool
        do {
            ok = try await Paste(text: text, press: press)
                .execute(pasteboard: simulator.pasteboard(), input: simulator.input())
        } catch {
            log("paste failed: \(error)")
            throw ExitCode.failure
        }
        print("{\"ok\":\(ok),\"action\":\"paste\"}")
        if !ok {
            throw ExitCode.failure
        }
    }
}
