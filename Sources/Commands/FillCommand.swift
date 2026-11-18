import BaguetteDevice
import ArgumentParser
import Foundation

/// `baguette fill --udid <UDID> --label <name> --text "<text>"`
///
/// Makes one named text field hold this text, and answers with what the field shows.
/// See `Fill` for the rules.
struct FillCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fill",
        abstract: "Make a named text field hold this text, and answer with what it shows"
    )

    @OptionGroup var options: DeviceOption

    @Option(help: "The text field, by its name from the answer's affordances, part of its label, or identifier.")
    var label: String

    @Option(help: "The text it should hold, in any language. Empty clears it.")
    var text: String

    @Flag(inversion: .prefixedNo, help: "Whether to answer with what can be done next and what the screen says, too.")
    var thenDescribeUI = true

    func run() async throws {
        let (device, accessibility) = try options.require(.accessibility)
        let pasteboard = try orExit { try device.require(.pasteboard) }
        let input = try orExit { try device.input() }
        // Only a device Device Hub can take over has a surface to read.
        let surface = try? device.require(.inputSurface)
        let outcome = await Fill(label: label, text: text).execute(
            accessibility: accessibility, pasteboard: pasteboard, input: input,
            inputTaken: { await surface?.shadowed() ?? false })
        say(FillDispatch.answer(
            outcome, thenDescribe: thenDescribeUI, accessibility: accessibility, style: options.affordanceStyle))
        if !outcome.isOK { throw ExitCode.failure }
    }
}
