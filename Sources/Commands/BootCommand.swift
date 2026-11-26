import BaguetteDevice
import BaguetteDeviceFamilies
import ArgumentParser
import Foundation

struct BootCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boot",
        abstract: "Boot a simulator headlessly"
    )

    @OptionGroup var options: DeviceOption

    @Flag(name: .customLong("no-heal"),
          help: "Leave the input surface alone even if Xcode 27's Device Hub has shadowed it (see `baguette heal`).")
    var noHeal = false

    func run() async throws {
        let device: any Device
        let power: any Power
        do {
            device = try options.device()
            power = try orExit { try device.require(.power) }
        } catch {
            throw ExitCode.failure
        }
        do {
            try power.turnOn()
            tell("Booted \(device.name)")
            if let advisory = SimulatorAppSettings.current.lifetime().advisory {
                warn(advisory)
            }
        } catch {
            tell("Boot failed: \(error)")
            throw ExitCode.failure
        }
        // Under Xcode 27, Device Hub attaches to the device as it boots
        // and — depending on a race inside backboardd — can leave the
        // legacy input surface dead for the rest of the boot. Nothing is
        // running yet, so the SpringBoard restart that fixes it is free.
        // Only a simulator has an input surface Device Hub can shadow.
        guard !noHeal, let surface = try? options.device().require(.inputSurface) else { return }
        do {
            if try await surface.healAfterBoot() == .reclaimed {
                tell(HealOutcome.reclaimed.summary)
            }
        } catch {
            warn("Input surface heal failed: \(error) — run `baguette heal --udid \(options.udid)` to retry")
        }
    }
}
