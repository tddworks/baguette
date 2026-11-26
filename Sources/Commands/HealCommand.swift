import BaguetteDevice
import BaguetteDeviceFamilies
import ArgumentParser
import Foundation

/// `baguette heal --udid <UDID>`
///
/// Reclaim a simulator's input surface from Xcode 27's Device Hub. Once
/// Device Hub's HID daemon attaches to a booted device, backboardd tears
/// down the legacy services baguette's touches and buttons ride and (on
/// iOS 27) never brings them back — gestures report `ok` and land
/// nowhere. This clears the state Device Hub published and restarts
/// backboardd, so it re-initialises with every legacy service live.
/// SpringBoard restarts with it: running apps are killed, the device is
/// not rebooted. `baguette boot` does the same automatically; this is
/// for a device booted some other way, or one Device Hub was opened on
/// later. See `docs/features/device-hub/README.md`.
struct HealCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "heal",
        abstract: "Reclaim the input surface after Xcode 27's Device Hub attaches (restarts SpringBoard)"
    )

    @OptionGroup var options: DeviceOption

    func run() async throws {
        let (_, surface) = try options.require(.inputSurface)
        do {
            let outcome = try await surface.heal()
            tell(outcome.summary)
        } catch {
            tell("Heal failed: \(error)")
            throw ExitCode.failure
        }
    }
}
