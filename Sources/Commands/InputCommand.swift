import BaguetteDevice
import BaguetteDeviceFamilies
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
            tell(error.message)
            throw ExitCode.failure
        } catch let error as FramebufferSelectionError {
            tell(error.message)
            throw ExitCode.failure
        } catch let exit as ExitCode {
            throw exit
        } catch {
            tell("display bind failed: \(error)")
            throw ExitCode.failure
        }
        let session = InputSession(
            input: input,
            pasteboard: try orExit { try device.require(.pasteboard) },
            accessibility: InputSession.accessibility(of: device),
            screenGuard: screenGuard,
            inputTaken: { await surface?.shadowed() ?? false }
        )
        // A long-lived session is worth one guest round-trip up front:
        // under Xcode 27, Device Hub can leave every gesture below
        // reporting ok while landing nowhere. Advise; the restart that
        // fixes it is the user's call mid-session.
        if let surface, await surface.shadowed(),
           let advisory = DeviceHubAttachment(attached: true).advisory(udid: device.id.raw) {
            warn(advisory)
        }
        tell("Input session started, reading from stdin")
        while let line = Terminal.current.readLine() {
            say(await session.answer(line))
            fflush(stdout)
        }
        tell("stdin closed, input session ending")
    }
}

/// One `baguette input` session: each stdin line answered by the role it
/// is for, one answer per line, in order.
struct InputSession: Sendable {
    let input: Abilities
    let pasteboard: any Pasteboard
    let accessibility: any Accessibility
    let inputTaken: @Sendable () async -> Bool
    private let dispatcher: GestureDispatcher

    init(
        input: Abilities, pasteboard: any Pasteboard, accessibility: any Accessibility,
        screenGuard: InputScreenGuard?, inputTaken: @escaping @Sendable () async -> Bool
    ) {
        self.input = input
        self.pasteboard = pasteboard
        self.accessibility = accessibility
        self.inputTaken = inputTaken
        self.dispatcher = GestureDispatcher(input: input, screenGuard: screenGuard)
    }

    /// The screen reader a session holds: the device's own, or — for a
    /// device that can't read its screen — one answering each describe or
    /// fill line with that refusal, while gestures go on.
    static func accessibility(of device: any Device) -> any Accessibility {
        do {
            return try device.require(.accessibility)
        } catch let refusal as DeviceError {
            return UnableAccessibility(refusal)
        } catch {
            return UnableAccessibility(.unable(ability: "accessibility", device: device.name))
        }
    }

    /// The answer to one line. `paste` / `copy` need the async pasteboard,
    /// so they — like `describe_ui`, `fill` and label presses — are read
    /// ahead of the sync gesture pipeline.
    func answer(_ line: String) async -> String {
        if let result = DescribeUIDispatch.dispatch(line: line, accessibility: accessibility) {
            return result
        }
        if let result = await FillDispatch.dispatch(
            line: line, accessibility: accessibility, pasteboard: pasteboard, input: input,
            inputTaken: inputTaken
        ) {
            return result
        }
        if let result = LabelTap.dispatch(
            line: line, accessibility: accessibility, gesture: { dispatcher.dispatch(line: $0) }
        ) {
            return result
        }
        if let result = ThenDescribe.dispatch(
            line: line, accessibility: accessibility, gesture: { dispatcher.dispatch(line: $0) }
        ) {
            return result
        }
        if let ack = await PasteDispatch.dispatch(line: line, pasteboard: pasteboard, input: input).ackJSON {
            return ack
        }
        if let ack = await CopyDispatch.dispatch(line: line, pasteboard: pasteboard, input: input).ackJSON {
            return ack
        }
        return dispatcher.dispatch(line: line)
    }
}
