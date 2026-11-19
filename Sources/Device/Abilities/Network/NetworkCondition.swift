import Foundation

/// How degraded a simulator's network is claimed to be: how long a request
/// waits before its first byte, how fast the response body is allowed to
/// arrive, how often a request fails outright, and whether the device is
/// simply disconnected.
///
/// ## Why this is validated here rather than at each entry point
///
/// Three surfaces publish a condition — the CLI, the HTTP route, and the
/// browser card — and a rule enforced by only some of them is a rule that
/// eventually lets nonsense through. Nonsense doesn't fail loudly: a
/// negative latency or a zero bandwidth reads to whoever is testing as "the
/// app is broken", days after anyone remembers arming it. So the failable
/// initialiser is the **only door**, exactly as `Coordinate`'s is.
///
/// ## Round-trip, not one-way
///
/// `latencyMs` is what a request waits in total before its first byte —
/// the figure a developer means by "300 ms of latency". Network Link
/// Conditioner instead states a *one-way* delay that traffic pays twice, so
/// `NetworkProfile` doubles NLC's numbers on the way in.
public struct NetworkCondition: Equatable, Sendable {

    /// Milliseconds a request waits before its first byte. Zero means no
    /// added delay.
    public let latencyMs: Double

    /// Kilobits per second the response body is paced at. `nil` means
    /// unmetered — "make requests wait, but let bytes arrive at full
    /// speed", which is a normal thing to ask for. Zero would have to mean
    /// either unlimited or nothing-gets-through, and it can't mean both, so
    /// zero is rejected instead.
    public let bandwidthKbps: Double?

    /// Percentage of requests failed outright, 0…100. Request-level, not
    /// packet-level: see `docs/features/network/README.md`.
    public let lossPercent: Double

    /// Whether the device reports no connection at all. Distinct from 100%
    /// loss on purpose — apps routinely special-case "not connected to the
    /// internet" and show a different screen for it than for a request that
    /// died in flight, and testing both is the point.
    public let isOffline: Bool

    /// The only validating door. Fails on anything that can't describe a
    /// network rather than clamping it, so a typo surfaces as an error at
    /// the moment it's made instead of as a throttle nobody asked for.
    public init?(
        latencyMs: Double = 0,
        bandwidthKbps: Double? = nil,
        lossPercent: Double = 0,
        isOffline: Bool = false
    ) {
        guard latencyMs.isFinite, latencyMs >= 0 else { return nil }
        guard lossPercent.isFinite, (0...100).contains(lossPercent) else { return nil }
        if let bandwidthKbps {
            guard bandwidthKbps.isFinite, bandwidthKbps > 0 else { return nil }
            // A metered condition must be pace-able. Rejecting here is what
            // makes `schedule` safe to reach for anywhere else: a condition
            // that validated always has one.
            guard NetworkSchedule(bandwidthKbps: bandwidthKbps) != nil else { return nil }
        }
        self.latencyMs = latencyMs
        self.bandwidthKbps = bandwidthKbps
        self.lossPercent = lossPercent
        self.isOffline = isOffline
    }

    /// The device reports no connection. Needs no other numbers — nothing
    /// leaves the app, so there is nothing to pace or lose.
    ///
    /// Can't fail: no latency, no bandwidth cap, no loss.
    public static let offline = NetworkCondition(isOffline: true)!

    /// Nothing is being conditioned — what `network clear` leaves behind.
    ///
    /// Can't fail: every figure is the neutral one.
    public static let unconditioned = NetworkCondition()!

    /// Whether this condition changes anything at all.
    ///
    /// Exists because "is a throttle on?" has to be answerable in one
    /// reading rather than by interpreting four numbers — the browser card
    /// decides whether to show its armed badge from this, and a forgotten
    /// throttle is the failure mode this whole feature has to design
    /// against.
    public var isUnconditioned: Bool {
        !isOffline && latencyMs == 0 && bandwidthKbps == nil && lossPercent == 0
    }
}
