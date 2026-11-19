import BaguetteDevice
import ArgumentParser
import Foundation

/// `baguette location <set|start|clear> --udid <UDID> …`
///
/// Drives the booted simulator's simulated GPS location — pin a single
/// point, run a moving route between waypoints, or clear back to the
/// device's live value. Backed by `xcrun simctl location` — a one-shot
/// subprocess, not the SimulatorHID gesture path. The value-domain
/// projection lives in `Device/Abilities/Location/`; the spawn is in
/// `Devices/Simulator/Internal/Location/SimctlLocation.swift`.
struct LocationCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "location",
        abstract: "Set, route, walk, or clear the booted simulator's simulated GPS location",
        subcommands: [Set.self, Start.self, Walk.self, Clear.self]
    )

    /// `baguette location set --udid <UDID> <lat,lon>`
    ///
    /// The position is a single `lat,lon` token rather than two `--lat` /
    /// `--lon` flags: a western/southern coordinate begins with `-`, and
    /// ArgumentParser would read `-122.03` as an unknown option. The
    /// comma-joined token sidesteps that and stays symmetric with the
    /// `start` waypoints. For a position whose latitude itself starts
    /// with `-`, pass `--` first: `location set --udid U -- -37.6,144.9`.
    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Pin the simulator to a lat,lon position"
        )

        @OptionGroup var options: DeviceOption

        @Argument(help: "Position as a lat,lon token, e.g. 37.3318,-122.0312")
        var position: String

        /// The parsed token as a validated Domain value — `nil` when it's
        /// malformed or out of range. The single mapping `run()` and the
        /// parsing tests both exercise.
        var coordinate: Coordinate? {
            Coordinate(token: position)
        }

        func run() async throws {
            let device = try options.device()
            let location = try orExit { try device.require(.location) }
            guard let coordinate else {
                tell("location set: latitude must be -90…90 and longitude -180…180")
                throw ExitCode.failure
            }
            do {
                try await location.set(coordinate)
            } catch {
                tell("location set failed: \(error)")
                throw ExitCode.failure
            }
            tell("Set \(device.name) location to \(coordinate.argument)")
        }
    }

    /// `baguette location start --udid <UDID> [--speed …] [--distance …] [--interval …] <lat,lon> <lat,lon>…`
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Run a moving route between two or more lat,lon waypoints"
        )

        @OptionGroup var options: DeviceOption

        @Option(help: "Speed in metres/second (default: simctl's 20)")
        var speed: Double?

        @Option(help: "Metres travelled between location updates")
        var distance: Double?

        @Option(help: "Seconds between location updates")
        var interval: Double?

        @Argument(help: "Waypoints as lat,lon tokens (two or more)")
        var waypoints: [String] = []

        /// The parsed waypoints + tuning as a validated route — `nil`
        /// when any token is malformed/out-of-range or fewer than two
        /// waypoints are given.
        var route: LocationRoute? {
            let coords = waypoints.compactMap(Coordinate.init(token:))
            guard coords.count == waypoints.count else { return nil }
            return LocationRoute(
                waypoints: coords, speed: speed, distance: distance, interval: interval
            )
        }

        func run() async throws {
            let device = try options.device()
            let location = try orExit { try device.require(.location) }
            guard let route else {
                tell("location start: give two or more valid lat,lon waypoints")
                throw ExitCode.failure
            }
            do {
                try await location.start(route)
            } catch {
                tell("location start failed: \(error)")
                throw ExitCode.failure
            }
            tell("Started \(device.name) route over \(route.waypoints.count) waypoints")
        }
    }

    /// `baguette location walk --udid <UDID> --bearing <deg> --speed <m/s> <lat,lon>`
    ///
    /// The shell-side spelling of the browser joystick's Walk mode: head
    /// off from a position in a compass direction, and keep going. Unlike
    /// `set` — which pins a *stationary* point, reported to apps with
    /// `course = -1` — a walk travels, so locationd derives
    /// `CLLocation.course` from the motion and hands the bearing to the
    /// app. Under the hood it's a `start` route projected over the
    /// horizon; `LocationWalk` owns that projection.
    ///
    /// Stop the walk with `location set` (pins it, course goes back to
    /// -1) or `location clear` (drops the override entirely).
    struct Walk: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "walk",
            abstract: "Walk from a lat,lon position along a compass bearing, driving CLLocation.course"
        )

        @OptionGroup var options: DeviceOption

        @Option(help: "Compass bearing in degrees clockwise from north (0 = N, 90 = E). Normalised onto the circle.")
        var bearing: Double

        @Option(help: "Speed in metres/second (1.4 ≈ walking, 25 ≈ driving)")
        var speed: Double

        @Argument(help: "Starting position as a lat,lon token, e.g. 37.3349,-122.0090")
        var position: String

        /// The parsed vector as a validated Domain value — `nil` when the
        /// origin is malformed / out of range or the speed isn't
        /// positive. The single mapping `run()` and the parsing tests
        /// both exercise.
        var walk: LocationWalk? {
            guard let origin = Coordinate(token: position) else { return nil }
            return LocationWalk(origin: origin, bearing: Bearing(degrees: bearing), speed: speed)
        }

        func run() async throws {
            let device = try options.device()
            let location = try orExit { try device.require(.location) }
            guard let walk else {
                tell("location walk: give a valid lat,lon origin and a speed above 0")
                throw ExitCode.failure
            }
            do {
                try await location.start(walk.route())
            } catch {
                tell("location walk failed: \(error)")
                throw ExitCode.failure
            }
            tell("""
                Walking \(device.name) from \(walk.origin.argument) \
                on bearing \(walk.bearing.degrees)° (\(walk.bearing.cardinal)) at \(walk.speed) m/s
                """)
        }
    }

    /// `baguette location clear --udid <UDID>`
    struct Clear: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clear",
            abstract: "Clear the simulated location, restoring live values"
        )

        @OptionGroup var options: DeviceOption

        func run() async throws {
            let device = try options.device()
            let location = try orExit { try device.require(.location) }
            do {
                try await location.clear()
            } catch {
                tell("location clear failed: \(error)")
                throw ExitCode.failure
            }
            tell("Cleared \(device.name) simulated location")
        }
    }
}
