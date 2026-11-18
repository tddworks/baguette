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
        let simulator = try options.simulator(for: .hinge)
        guard simulator.canAcceptInput else {
            log("Device \(simulator.name) is not booted")
            Foundation.exit(1)
        }
        if pose == nil && angle == nil {
            let current = simulator.hinge().angle()
            print(#"{"ok":true,"angleDegrees":\#(current.map { String($0.degrees) } ?? "null")}"#)
            return
        }
        let command: HingeCommand
        do {
            command = try HingeCommand.parse(pose: pose, angle: angle, duration: duration)
        } catch let error as HingeCommandError {
            log(Server.hingeCommandMessage(error))
            Foundation.exit(2)
        }
        do {
            try simulator.hinge().fold(to: command.degrees, over: command.duration)
        } catch {
            let delivery = PoseDelivery(failure: error)
            log(delivery == .unconfirmed
                ? "Hinge move unconfirmed: \(error) Read the hinge before retrying."
                : "Hinge could not be driven: \(error)")
            Foundation.exit(delivery.exitStatus)
        }
        print(#"{"ok":true,"angleDegrees":\#(command.degrees)}"#)
    }
}
