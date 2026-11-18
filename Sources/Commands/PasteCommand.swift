import BaguetteDevice
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
        let device = try options.device()
        let pasteboard = try orExit { try device.require(.pasteboard) }
        let input = try orExit { try device.input() }
        let ok: Bool
        do {
            ok = try await Paste(text: text, press: press)
                .execute(pasteboard: pasteboard, input: input)
        } catch {
            tell("paste failed: \(error)")
            throw ExitCode.failure
        }
        say("{\"ok\":\(ok),\"action\":\"paste\"}")
        if !ok {
            throw ExitCode.failure
        }
    }
}
