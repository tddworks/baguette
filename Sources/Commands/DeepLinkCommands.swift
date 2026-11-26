import BaguetteDevice
import BaguetteDeviceFamilies
import ArgumentParser
import Foundation

/// `baguette openurl --udid <UDID> <url>`
///
/// Opens a deep link on a booted simulator — the CLI half of the console
/// surface, and the thing `baguette serve`'s URL bar drives.
///
/// The one behaviour that distinguishes this from `xcrun simctl openurl`
/// is the warning: an `https://` universal link dispatches fine and then
/// opens **Safari** rather than the app, because the simulator doesn't
/// resolve associated domains the way a device does. Every existing tool
/// does this silently, leaving the developer to guess whether their
/// entitlement, their apple-app-site-association file, or the simulator
/// is at fault. `DeepLink.routing` names the case, so we say it out loud
/// before dispatching.
struct OpenURLCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "openurl",
        abstract: "Open a deep link on the booted simulator"
    )

    @OptionGroup var options: DeviceOption

    @Argument(help: "The URL to open, e.g. myapp://profile/42")
    var url: String

    func run() async throws {
        let device = try options.device()
        let apps = try orExit { try device.require(.apps) }
        guard let link = DeepLink.from(url) else {
            tell("Not a URL (expected a scheme, e.g. myapp://path): \(url)")
            throw ExitCode.failure
        }

        if link.routing == .browser {
            tell("""
                Warning: \(link.scheme):// lands in Safari on the simulator, not your app. \
                If an app claims the domain, iOS then shows an "Open in …?" dialog that \
                needs a tap, so this never completes unattended. For an automated check, \
                use the app's custom scheme — `baguette schemes` lists them.
                """)
        }

        do {
            try await apps.open(link)
        } catch {
            tell("openurl failed: \(error)")
            throw ExitCode.failure
        }
        tell("Opened \(link.url.absoluteString) on \(device.name)")
    }
}

/// `baguette schemes --udid <UDID>`
///
/// Lists the URL schemes the device's installed apps answer to — the
/// inventory behind console completion, and useful on its own when you
/// know an app handles *something* but not what it's called.
///
/// Schemes are ranked the same way the console ranks them: an app's own
/// readable scheme first, aliases after.
struct SchemesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schemes",
        abstract: "List URL schemes the booted simulator's apps answer to"
    )

    @OptionGroup var options: DeviceOption

    @Flag(name: .long, help: "Emit JSON instead of a table")
    var json = false

    func run() async throws {
        let device = try options.device()
        let apps = try orExit { try device.require(.apps) }

        let installed: [InstalledApp]
        do {
            installed = try await apps.installed()
        } catch {
            tell("listing apps failed: \(error)")
            throw ExitCode.failure
        }

        let suggestions = SchemeSuggestion.matching("", in: installed)
        guard !suggestions.isEmpty else {
            tell("No app on \(device.name) registers a URL scheme")
            return
        }

        if json {
            let rows = suggestions.map {
                ["scheme": $0.scheme, "url": $0.completion,
                 "app": $0.appName, "bundleId": $0.bundleIdentifier]
            }
            let data = try JSONSerialization.data(
                withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]
            )
            say(String(decoding: data, as: UTF8.self))
        } else {
            let width = suggestions.map(\.completion.count).max() ?? 0
            for suggestion in suggestions {
                let padded = suggestion.completion.padding(
                    toLength: width, withPad: " ", startingAt: 0
                )
                say("\(padded)  \(suggestion.appName)")
            }
        }
    }
}
