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

    /// The `screen` JSON a `describe-ui` result carried. Coordinate input
    /// is pinned to that observation: a contact goes down or moves only
    /// while a fresh observation still matches it, and it always lifts
    /// on the binding that received it.
    @Option(help: "Require fresh observations to match this describe-ui screen JSON before coordinate input")
    var expectedScreen: String?

    /// Rejected here rather than in `run()` so a malformed flag is not
    /// masked by the device lookup that used to precede it: `--display
    /// carply` against an absent udid reported `Device ... not found`,
    /// which is the wrong end of a command line that was itself wrong.
    /// The value is wrong regardless of what is booted, and `screenshot`
    /// already fails it at the same point.
    mutating func validate() throws {
        do {
            let plan = try StreamDisplayPlan.from(cliFlag: display)
            if let expectedScreen {
                guard plan.kind == .phone else {
                    throw ValidationError("--expected-screen requires the phone display")
                }
                _ = try ExpectedScreen(json: expectedScreen)
            }
        } catch let error as DisplayFlagError {
            throw ValidationError(error.message)
        } catch let error as ExpectedScreen.Failure {
            throw ValidationError(error.localizedDescription)
        }
    }

    func run() async {
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            Foundation.exit(1)
        }
        // Gestures go to the planned plane's Input; pasteboard is a
        // device-level service and stays on the simulator itself.
        let plan: StreamDisplayPlan
        let input: any Input
        let screenGuard: InputScreenGuard?
        do {
            plan = try StreamDisplayPlan.from(cliFlag: display)
            if let expectedScreen {
                let checked = try simulator.displays().phone.input(expected: ExpectedScreen(json: expectedScreen))
                input = checked.input
                screenGuard = checked.screenGuard
            } else {
                input = try plan.bind(to: simulator).input
                screenGuard = nil
            }
        } catch let error as DisplayFlagError {
            log(error.message)
            Foundation.exit(1)
        } catch let error as FramebufferSelectionError {
            log(error.message)
            Foundation.exit(1)
        } catch {
            log("display bind failed: \(error)")
            Foundation.exit(1)
        }
        let pasteboard = simulator.pasteboard()
        let dispatcher = GestureDispatcher(input: input, screenGuard: screenGuard)
        // A long-lived session is worth one guest round-trip up front:
        // under Xcode 27, Device Hub can leave every gesture below
        // reporting ok while landing nowhere. Advise; the restart that
        // fixes it is the user's call mid-session.
        if await SimctlInputSurface().shadowed(on: simulator),
           let advisory = DeviceHubAttachment(attached: true).advisory(udid: simulator.udid) {
            warn(advisory)
        }
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
