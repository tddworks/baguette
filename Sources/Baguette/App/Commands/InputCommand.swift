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

    /// A CarPlay session that must not open the host External Displays
    /// panel: with no CarPlay framebuffer attached the command fails
    /// instead of enabling one.
    @Flag(help: "Require the target display to be attached; never enable CarPlay implicitly")
    var requireExistingDisplay = false

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
            let plan = try StreamDisplayPlan.from(cliFlag: display, requireExistingDisplay: requireExistingDisplay)
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

    func run() async throws {
        let device = try options.device()
        // Only a simulator has an input surface Device Hub can shadow.
        let surface = try? device.require(.inputSurface)
        // Gestures go to the planned plane's input; pasteboard is a
        // device-level role on the device itself.
        let plan: StreamDisplayPlan
        let input: Abilities
        let screenGuard: InputScreenGuard?
        do {
            plan = try StreamDisplayPlan.from(cliFlag: display, requireExistingDisplay: requireExistingDisplay)
            if let expectedScreen {
                let checked = try orExit { try device.require(.displays) }
                    .phone.input(expected: ExpectedScreen(json: expectedScreen))
                input = .input(of: device.name, all: checked.input)
                screenGuard = checked.screenGuard
            } else {
                input = try orExit { try plan.input(on: device) }
                screenGuard = nil
            }
        } catch let error as DisplayFlagError {
            log(error.message)
            Foundation.exit(1)
        } catch let error as FramebufferSelectionError {
            log(error.message)
            Foundation.exit(1)
        } catch let exit as ExitCode {
            throw exit
        } catch {
            log("display bind failed: \(error)")
            Foundation.exit(1)
        }
        let pasteboard = try orExit { try device.require(.pasteboard) }
        // A device that can't read its screen still takes gestures; its
        // describe / fill / label lines answer with that refusal.
        let accessibility: any Accessibility
        do {
            accessibility = try device.require(.accessibility)
        } catch let refusal as DeviceError {
            accessibility = UnableAccessibility(refusal)
        }
        let dispatcher = GestureDispatcher(input: input, screenGuard: screenGuard)
        // A long-lived session is worth one guest round-trip up front:
        // under Xcode 27, Device Hub can leave every gesture below
        // reporting ok while landing nowhere. Advise; the restart that
        // fixes it is the user's call mid-session.
        if let surface, await surface.shadowed(),
           let advisory = DeviceHubAttachment(attached: true).advisory(udid: device.id.raw) {
            warn(advisory)
        }
        log("Input session started, reading from stdin")
        while let line = readLine() {
            // `paste` / `copy` need the async pasteboard surface, so
            // they are intercepted ahead of the sync gesture pipeline
            // — same shape as `describe_ui` on the WS path. Awaiting
            // in-line preserves the one-line-in/one-ack-out order.
            if let result = DescribeUIDispatch.dispatch(line: line, accessibility: accessibility) {
                print(result)
            } else if let result = await FillDispatch.dispatch(
                line: line, accessibility: accessibility, pasteboard: pasteboard, input: input,
                inputTaken: { await surface?.shadowed() ?? false }
            ) {
                print(result)
            } else if let result = LabelTap.dispatch(
                line: line, accessibility: accessibility, gesture: { dispatcher.dispatch(line: $0) }
            ) {
                print(result)
            } else if let result = ThenDescribe.dispatch(
                line: line, accessibility: accessibility, gesture: { dispatcher.dispatch(line: $0) }
            ) {
                print(result)
            } else if let ack = await PasteDispatch.dispatch(
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
