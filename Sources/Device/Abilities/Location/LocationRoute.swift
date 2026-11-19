import Foundation

/// A moving-location route — two or more `Coordinate` waypoints simctl
/// interpolates between over time, optionally tuned by `speed` (m/s),
/// `distance` (metres between updates) or `interval` (seconds between
/// updates). A single point isn't a route — it's a `set` — so the
/// initializer requires at least two waypoints, and any supplied tuning
/// value must be positive.
///
/// `startArguments` is the pure projection to the argv tail after
/// `simctl location <udid> start`: the equals-form flags simctl accepts
/// (`--speed=…`) in a stable order, then the waypoint tokens. Numbers
/// render locale-independently and drop a trailing `.0` so `260.0`
/// matches simctl's documented `--speed=260` spelling.
public struct LocationRoute: Equatable, Sendable {
    public var waypoints: [Coordinate]
    public var speed: Double?
    public var distance: Double?
    public var interval: Double?

    /// Fails when fewer than two waypoints are given or any supplied
    /// tuning value is non-positive.
    public init?(
        waypoints: [Coordinate],
        speed: Double? = nil,
        distance: Double? = nil,
        interval: Double? = nil
    ) {
        guard waypoints.count >= 2 else { return nil }
        if let speed, speed <= 0 { return nil }
        if let distance, distance <= 0 { return nil }
        if let interval, interval <= 0 { return nil }
        self.waypoints = waypoints
        self.speed = speed
        self.distance = distance
        self.interval = interval
    }

    /// The argv tail after `simctl location <udid> start`. Flags appear
    /// in a stable order so the output is deterministic and testable;
    /// simctl accepts them in any order.
    public var startArguments: [String] {
        var args: [String] = []
        if let speed { args.append("--speed=\(Self.num(speed))") }
        if let distance { args.append("--distance=\(Self.num(distance))") }
        if let interval { args.append("--interval=\(Self.num(interval))") }
        args += waypoints.map(\.argument)
        return args
    }

    /// Render a tuning value without a redundant trailing `.0`, keeping
    /// `.` as the decimal separator regardless of locale.
    private static func num(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : "\(value)"
    }
}
