import BaguetteDevice
import BaguetteDeviceFamilies
import ArgumentParser
import Foundation

/// `baguette hinge --udid <UDID> --pose open` / `--angle 95 [--duration 0.8]`
///
/// Moves iPhone Duo's hinge — Device Hub's pose picker from the CLI. The
/// sweep runs inside the guest (`HingeControl`, spawned with `simctl
/// spawn`), which sends the same HID pose events Device Hub does;
/// SpringBoard swaps panels and `HingeControl` reads the angle back. With
/// no flag it prints the current angle. See `docs/features/hinge/README.md`.
struct HingeCLICommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hinge",
        abstract: "Read or move iPhone Duo's hinge"
    )

    @OptionGroup var options: DeviceOption

    @Option(help: "A pose: closed (0°), open (130°) or flat (180°)")
    var pose: String?

    @Option(help: "An angle in degrees, 0–180")
    var angle: String?

    @Option(help: "Seconds the sweep takes, 0–60 (default: Device Hub's 0.8)")
    var duration: String?

    func run() throws {
        // `.hinge` needs a booted device: Devices refuses the rest, saying so.
        let (_, hinge) = try options.require(.hinge)
        if pose == nil && angle == nil {
            let current = hinge.angle()
            say(#"{"ok":true,"angleDegrees":\#(current.map { String($0.degrees) } ?? "null")}"#)
            return
        }
        let command: HingeCommand
        do {
            command = try HingeCommand.parse(pose: pose, angle: angle, duration: duration)
        } catch let error as HingeCommandError {
            tell(Server.hingeCommandMessage(error))
            throw ExitCode(2)
        }
        do {
            try hinge.fold(to: command.degrees, over: command.duration)
        } catch {
            let delivery = PoseDelivery(failure: error)
            tell(delivery == .unconfirmed
                ? "Hinge move unconfirmed: \(error) Read the hinge before retrying."
                : "Hinge could not be driven: \(error)")
            throw ExitCode(delivery.exitStatus)
        }
        say(#"{"ok":true,"angleDegrees":\#(command.degrees)}"#)
    }
}
