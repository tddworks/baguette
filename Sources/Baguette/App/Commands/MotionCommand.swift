import ArgumentParser
import Foundation

/// `baguette motion <start|set|stop> --udid <UDID> …`
///
/// Drives what a simulator's apps read from CoreMotion — `CMMotionActivity`,
/// `CMPedometer` counters, and `CMMotionManager` samples.
///
/// Unlike `location`, there is **no `simctl` verb behind this**. All three
/// surfaces report unavailable in a stock simulator and locationd refuses a
/// motion-activity subscription outright, so baguette injects
/// `VirtualMotion.dylib` into apps and answers from a published intent. Two
/// consequences the help text repeats, because they surprise people:
///
/// - Only apps launched **after** `motion start` see anything; dyld inserts
///   at exec time.
/// - `motion stop` parks the device as stationary and stops future launches
///   loading the dylib.
struct MotionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "motion",
        abstract: "Drive CoreMotion — activity, pedometer, and device motion",
        discussion: """
            Motion is injected, not simulated by simctl: relaunch the target \
            app after `motion start` or it won't see anything. Once running, \
            `location walk` and `location start` drive the activity from the \
            speed they're moving at.
            """,
        subcommands: [Start.self, Set.self, Stop.self]
    )

    /// Speeds each kind is reported at when none is given — the same presets
    /// the browser's Walk mode offers, so the CLI and the UI agree.
    static func defaultSpeed(for kind: MotionKind) -> Double {
        switch kind {
        case .walking: return 1.4
        case .running: return 3.5
        case .cycling: return 6
        case .automotive: return 13.4
        case .stationary, .unknown: return 0
        }
    }

    /// `--activity` shared by `start` and `set`.
    struct ActivityOption: ParsableArguments {
        @Option(name: .customLong("activity"),
                help: "stationary | walking | running | cycling | automotive")
        var activity: String = MotionKind.walking.rawValue

        @Option(help: "Speed in metres/second (default: the kind's usual pace)")
        var speed: Double?

        @Option(help: "low | medium | high")
        var confidence: String = MotionConfidence.high.rawValue

        func validate() throws {
            guard MotionKind(rawValue: activity) != nil, activity != MotionKind.unknown.rawValue
            else {
                throw ValidationError(
                    "Unknown activity '\(activity)'. Use one of: stationary, walking, "
                    + "running, cycling, automotive.")
            }
            guard MotionConfidence(rawValue: confidence) != nil else {
                throw ValidationError(
                    "Unknown confidence '\(confidence)'. Use one of: low, medium, high.")
            }
            // A negative speed classifies as `unknown`, which would arm a
            // session reporting no motion at all — a confusing way to spell
            // "invalid input".
            if let speed, speed < 0 {
                throw ValidationError("--speed must not be negative (got \(speed)).")
            }
        }

        var kind: MotionKind { MotionKind(rawValue: activity) ?? .walking }
        var motionConfidence: MotionConfidence {
            MotionConfidence(rawValue: confidence) ?? .high
        }
        var resolvedSpeed: Double { speed ?? MotionCommand.defaultSpeed(for: kind) }
    }

    /// `baguette motion start --udid <UDID> [--activity …] [--speed …]`
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Arm motion and report an activity (relaunch the app afterwards)"
        )

        @OptionGroup var options: DeviceOption
        @OptionGroup var activityOptions: ActivityOption

        var kind: MotionKind { activityOptions.kind }
        var resolvedSpeed: Double { activityOptions.resolvedSpeed }

        func run() async throws {
            let simulator = try MotionCommand.resolve(options)
            try await MotionCommand.publish(
                kind: kind, confidence: activityOptions.motionConfidence,
                speed: resolvedSpeed, on: simulator)
            log("Motion armed on \(simulator.name): \(kind.rawValue) at "
                + "\(resolvedSpeed) m/s. Relaunch the app to pick it up.")
        }
    }

    /// `baguette motion set --udid <UDID> --activity <kind>`
    ///
    /// Same publish as `start`; separate verb because "change what it's
    /// doing" reads differently from "turn this on", and only `start`
    /// mentions the relaunch.
    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Change the reported activity without re-arming"
        )

        @OptionGroup var options: DeviceOption
        @OptionGroup var activityOptions: ActivityOption

        var kind: MotionKind { activityOptions.kind }
        var resolvedSpeed: Double { activityOptions.resolvedSpeed }

        func run() async throws {
            let simulator = try MotionCommand.resolve(options)
            try await MotionCommand.publish(
                kind: kind, confidence: activityOptions.motionConfidence,
                speed: resolvedSpeed, on: simulator)
            log("\(simulator.name) motion: \(kind.rawValue) at \(resolvedSpeed) m/s")
        }
    }

    /// `baguette motion stop --udid <UDID>`
    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "stop",
            abstract: "Park the device as stationary and stop injecting motion"
        )

        @OptionGroup var options: DeviceOption

        func run() async throws {
            let simulator = try MotionCommand.resolve(options)
            let motion = simulator.motion()
            do {
                // Park before disarming: an app already running still has the
                // dylib loaded, so the last thing it reads must say "not
                // moving" rather than a stale walk. The totals already walked
                // ride along — a pedometer that zeroed on stop would make an
                // app's chart jump backwards.
                let now = Date().timeIntervalSince1970
                let ledger = MotionLedger.resuming(from: motion.published(), at: now)
                try await motion.publish(
                    .stationary(startedAt: now, stepsBefore: ledger.steps,
                                distanceBefore: ledger.metres),
                    on: simulator)
                try await motion.clear(on: simulator)
            } catch {
                log("motion stop failed: \(error)")
                throw ExitCode.failure
            }
            log("Motion stopped on \(simulator.name)")
        }
    }

    private static func resolve(_ options: DeviceOption) throws -> any Simulator {
        try options.simulator(for: .motion)
    }

    /// Publishes a new leg, carrying the pedometer's running totals forward.
    ///
    /// Each CLI invocation is a fresh process with no session state, so the
    /// totals are recovered from the intent already published — otherwise
    /// every `motion set` would republish zeroes and an app's step count
    /// would restart on each command.
    private static func publish(kind: MotionKind, confidence: MotionConfidence,
                                speed: Double, on simulator: any Simulator) async throws {
        let motion = simulator.motion()
        let now = Date().timeIntervalSince1970
        let ledger = MotionLedger.resuming(from: motion.published(), at: now)
        let intent = ledger.intent(kind: kind, confidence: confidence, speed: speed,
                                   startedAt: now)
        do {
            try await motion.publish(intent, on: simulator)
        } catch {
            log("motion failed: \(error)")
            throw ExitCode.failure
        }
    }
}
