import BaguetteDevice
import BaguetteDeviceFamilies
import ArgumentParser
import Foundation

/// `baguette lifetime` — show or change whether Simulator.app leaves
/// devices booted when their window closes or the app quits.
///
/// This is deliberately an explicit command rather than something
/// `boot` / `serve` apply on your behalf. The keys live in Xcode's
/// preferences domain, not baguette's: the change is machine-wide,
/// persists after baguette is uninstalled, and is invisible unless
/// somebody typed it. `serve` and `boot` only *warn* — see
/// `SimulatorLifetime.advisory`.
struct LifetimeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lifetime",
        abstract: "Show or change whether Simulator.app leaves devices booted",
        discussion: """
            Simulator.app shuts a device down when you close its window \
            or quit the app. That kills devices baguette is driving — \
            including ones another toolchain booted for you.

            Run with no flags to see the current policy. This setting is \
            Simulator.app's own, so it applies to every simulator on the \
            machine, not just one device.
            """
    )

    @Flag(name: .long, help: "Leave devices booted when a window closes or Simulator.app quits.")
    var detach = false

    @Flag(name: .long, help: "Restore Apple's default: closing a window or quitting shuts the device down.")
    var shutdown = false

    func validate() throws {
        if detach && shutdown {
            throw ValidationError("Pass only one of --detach or --shutdown.")
        }
    }

    /// nil when the command was invoked with no flags, i.e. read-only.
    var desired: SimulatorLifetime? {
        if detach { return .detached }
        if shutdown { return .appleDefault }
        return nil
    }

    func run() throws {
        let settings = SimulatorAppSettings.current
        let current = settings.lifetime()

        guard let desired else {
            report(current)
            return
        }

        let change = current.change(
            to: desired,
            simulatorAppRunning: settings.appRunning()
        )

        switch change {
        case .unchanged:
            tell("Already set — \(Self.headline(desired))")
        case .applied(let restartSimulatorApp):
            do {
                try settings.write(desired)
            } catch {
                tell("Could not change the lifetime policy: \(error)")
                throw ExitCode.failure
            }
            tell(Self.headline(desired))
            if restartSimulatorApp {
                warn("""
                    Simulator.app is running and may overwrite this when it \
                    quits — quit and reopen it to be sure the change sticks.
                    """)
            }
        }
    }

    private func report(_ lifetime: SimulatorLifetime) {
        for line in Self.report(lifetime, colored: terminalColorized(STDOUT_FILENO)) { say(line) }
    }

    /// The policy in force, as the read-only command prints it.
    static func report(_ lifetime: SimulatorLifetime, colored: Bool) -> [String] {
        var lines = [
            "Simulator lifetime (\(SimulatorAppPreferences.domain))",
            "  closing a window   \(effect(lifetime.detachOnWindowClose))",
            "  quitting the app   \(effect(lifetime.detachOnAppQuit))",
            "",
        ]
        if let advisory = lifetime.advisory {
            // The report is the command's product, so it goes to stdout
            // — but the advisory is the same problem `serve` warns
            // about, and it would read oddly as the only uncoloured
            // warning in the tool.
            lines.append(TerminalStyle.warning(advisory, colored: colored))
        } else {
            lines.append("Booted devices survive Simulator.app.")
        }
        return lines
    }

    private static func effect(_ detaches: Bool) -> String {
        detaches ? "leaves the device booted" : "shuts the device down"
    }

    static func headline(_ lifetime: SimulatorLifetime) -> String {
        lifetime.survivesSimulatorApp
            ? "Simulator.app will leave booted devices running."
            : "Simulator.app will shut devices down on window close and quit."
    }
}

/// Simulator.app's own settings, as `lifetime`, `boot` and `serve` read
/// them: the lifetime policy in force, writing a new one, and whether the
/// app is running (it may hold a cached copy). Injected so those commands
/// can be run in a test without reading or rewriting this Mac's settings.
struct SimulatorAppSettings: Sendable {
    let lifetime: @Sendable () -> SimulatorLifetime
    let write: @Sendable (SimulatorLifetime) throws -> Void
    let appRunning: @Sendable () -> Bool

    /// This run's settings: this Mac's, unless a test stands in.
    @TaskLocal static var current: SimulatorAppSettings = .host
}
