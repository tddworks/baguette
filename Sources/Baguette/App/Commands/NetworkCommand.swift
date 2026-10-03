import ArgumentParser
import Foundation

/// `baguette network <set|clear|status> --udid <UDID> …`
///
/// Conditions what a simulator's apps see of the network — latency,
/// downlink bandwidth, request loss, and hard offline.
///
/// Like `motion`, there is **no `simctl` verb behind this**, and the reason
/// is worth repeating in the help text: the host's own tooling (Network
/// Link Conditioner, and the `dnctl` / `pfctl` rules under it) is
/// system-wide, because simulator apps use the host's network stack as the
/// host user. Conditioning one simulator that way means degrading the whole
/// Mac. So baguette injects `VirtualNetwork.dylib` into apps instead, with
/// the two consequences that surprise people:
///
/// - Only apps launched **after** `network set` are conditioned; dyld
///   inserts at exec time. Changing the condition afterwards reaches a
///   running app fine — only the first arm needs the relaunch.
/// - `network clear` un-conditions apps that are already running as well as
///   disarming future launches.
struct NetworkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "network",
        abstract: "Condition the network — latency, bandwidth, loss, offline",
        discussion: """
            Conditioning is injected, not simulated by simctl: relaunch the \
            target app after `network set` or it won't be conditioned. \
            Changing the condition afterwards reaches a running app without \
            a relaunch.

            Only URLSession-shaped traffic is affected — REST, GraphQL, image \
            loading and URLSessionWebSocketTask are (WebSockets take latency, \
            loss and offline, but not bandwidth). An SDK that opens its own \
            socket, and WKWebView page loads, are not. Run `network` on its \
            own to see what is currently applied.
            """,
        subcommands: [Set.self, Clear.self, Status.self],
        defaultSubcommand: Status.self
    )

    /// How the condition is stated: a named preset, explicit numbers, or
    /// `--offline`.
    ///
    /// Exactly one of those three, enforced in `validate()`. "3G but
    /// lossier" reads like it ought to work, and once it does, whether the
    /// preset or the flag wins becomes something the user has to remember —
    /// so mixing is refused outright rather than resolved by a rule.
    struct ConditionOptions: ParsableArguments {

        @Option(help: ArgumentHelp(
            "Named preset",
            discussion: "wifi | dsl | lte | 3g | edge | very-bad-network | 100-loss"))
        var profile: String?

        @Option(help: "Round-trip latency in milliseconds")
        var latency: Double?

        @Option(help: "Downlink bandwidth in kbps (omit to leave it unmetered)")
        var bandwidth: Double?

        @Option(help: "Percentage of requests failed outright, 0-100")
        var loss: Double?

        @Flag(help: "Report no connection at all, as though the device were offline")
        var offline = false

        private var namesNumbers: Bool { latency != nil || bandwidth != nil || loss != nil }

        /// The condition being asked for, or `nil` when the flags don't
        /// describe one. `validate()` has already rejected every `nil` case
        /// by the time a subcommand runs.
        var condition: NetworkCondition? {
            if let profile { return NetworkProfile(rawValue: profile)?.condition }
            if offline { return .offline }
            guard namesNumbers else { return nil }
            return NetworkCondition(
                latencyMs: latency ?? 0, bandwidthKbps: bandwidth, lossPercent: loss ?? 0)
        }

        func validate() throws {
            let sources = [profile != nil, offline, namesNumbers].filter { $0 }.count
            guard sources > 0 else {
                throw ValidationError(
                    "Nothing to apply. Name a preset (--profile 3g), some numbers "
                    + "(--latency 300 --bandwidth 400 --loss 5), or --offline.")
            }
            guard sources == 1 else {
                throw ValidationError(
                    "Use one of --profile, --offline, or explicit numbers — not several. "
                    + "A preset already states every number it conditions.")
            }
            if let profile, NetworkProfile(rawValue: profile) == nil {
                throw ValidationError(
                    "Unknown profile '\(profile)'. Use one of: "
                    + NetworkProfile.allCases.map(\.rawValue).joined(separator: ", ") + ".")
            }
            guard condition != nil else {
                throw ValidationError(
                    "Those numbers don't describe a network. Latency is milliseconds and "
                    + "can't be negative, bandwidth is kbps and must be above zero, and "
                    + "loss is a percentage between 0 and 100.")
            }
        }
    }

    /// `baguette network set --udid <UDID> …`
    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Condition the network (relaunch the app afterwards)"
        )

        @OptionGroup var options: DeviceOption
        @OptionGroup var condition: ConditionOptions

        func run() async throws {
            let simulator = try NetworkCommand.resolve(options)
            // `validate()` guarantees this.
            let applied = condition.condition ?? .unconditioned
            do {
                try await simulator.network().apply(applied, on: simulator)
            } catch {
                log("network set failed: \(error)")
                throw ExitCode.failure
            }
            log("Network conditioned on \(simulator.name): \(applied.summary). "
                + "Relaunch the app to pick it up.")
        }
    }

    /// `baguette network clear --udid <UDID>`
    struct Clear: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clear",
            abstract: "Stop conditioning, including for apps already running"
        )

        @OptionGroup var options: DeviceOption

        func run() async throws {
            let simulator = try NetworkCommand.resolve(options)
            do {
                try await simulator.network().clear(on: simulator)
            } catch {
                log("network clear failed: \(error)")
                throw ExitCode.failure
            }
            log("Network conditioning cleared on \(simulator.name)")
        }
    }

    /// `baguette network status --udid <UDID>` — and what plain
    /// `baguette network` runs.
    ///
    /// Exists because of the one failure mode this feature has to design
    /// against: a throttle nobody remembers arming doesn't announce itself,
    /// it just makes the app feel slow. Answering "is anything on?" has to
    /// be one command, not an invitation to go reading `/tmp`.
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Report the condition currently applied"
        )

        @OptionGroup var options: DeviceOption

        func run() async throws {
            let simulator = try NetworkCommand.resolve(options)
            guard let applied = try await simulator.network().current(on: simulator) else {
                log("\(simulator.name): no network conditioning applied.")
                return
            }
            log("\(simulator.name) network: \(applied.summary)")
        }
    }

    private static func resolve(_ options: DeviceOption) throws -> any Simulator {
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            throw ExitCode.failure
        }
        return simulator
    }
}

extension NetworkCondition {
    /// One line a human can read back, for the CLI and for logs.
    var summary: String {
        if isOffline { return "offline" }
        if isUnconditioned { return "nothing" }
        var parts: [String] = []
        if latencyMs > 0 { parts.append("\(Int(latencyMs)) ms latency") }
        if let bandwidthKbps { parts.append("\(Int(bandwidthKbps)) kbps") }
        if lossPercent > 0 { parts.append("\(Int(lossPercent))% loss") }
        return parts.joined(separator: ", ")
    }
}
