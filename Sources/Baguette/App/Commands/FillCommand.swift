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

    @Flag(inversion: .prefixedNo, help: "Answer with what can be done next and what the screen says, too.")
    var thenDescribeUI = true

    func run() async throws {
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            throw ExitCode.failure
        }
        let outcome = await Fill(label: label, text: text).execute(
            accessibility: simulator.accessibility(), pasteboard: simulator.pasteboard(), input: simulator.input(),
            inputTaken: { await SimctlInputSurface().shadowed(on: simulator) })
        print(FillDispatch.answer(
            outcome, thenDescribe: thenDescribeUI, accessibility: simulator.accessibility(), style: options.affordanceStyle))
        if !outcome.isOK { throw ExitCode.failure }
    }
}
