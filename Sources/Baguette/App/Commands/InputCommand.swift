import ArgumentParser
import Foundation

struct InputCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "input",
        abstract: "Read newline-delimited JSON gestures from stdin, ack each on stdout"
    )

    @OptionGroup var options: DeviceOption

    /// Which plane gestures land on: `phone` (default) or `carplay`.
    /// CarPlay builds its digitizer and fails closed when the plane
    /// has no framebuffer behind it.
    @Option(help: "Target display plane: phone | carplay")
    var display: String?

    func run() async {
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            Foundation.exit(1)
        }
        // Gestures go to the planned plane's Input; pasteboard is a
        // device-level service and stays on the simulator itself.
        let plan: StreamDisplayPlan
        let bound: (screen: any Screen, input: any Input)
        do {
            plan = try StreamDisplayPlan.from(cliFlag: display)
            bound = try plan.bind(to: simulator)
        } catch let error as DisplayFlagError {
            log(error.message)
            Foundation.exit(1)
        } catch {
            log("display bind failed: \(error)")
            Foundation.exit(1)
        }
        let input = bound.input
        let pasteboard = simulator.pasteboard()
        let dispatcher = GestureDispatcher(input: input)
        log("Input session started, reading from stdin")
        while let line = readLine() {
            // `paste` / `copy` need the async pasteboard surface, so
            // they are intercepted ahead of the sync gesture pipeline
            // — same shape as `describe_ui` on the WS path. Awaiting
            // in-line preserves the one-line-in/one-ack-out order.
            if let ack = await PasteDispatch.dispatch(
                line: line, pasteboard: pasteboard, input: input
            ).ackJSON {
                print(ack)
            } else if let ack = await CopyDispatch.dispatch(
                line: line, pasteboard: pasteboard, input: input
            ).ackJSON {
                print(ack)
            } else {
                print(dispatcher.dispatch(line: line))
            }
            fflush(stdout)
        }
        log("stdin closed, input session ending")
    }
}
