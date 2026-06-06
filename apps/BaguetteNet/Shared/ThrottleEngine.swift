import Foundation

/// What the extension should do with a flow, computed purely from a
/// `NetworkProfile` and how many bytes have already passed. No
/// NetworkExtension types here, so the math is unit-testable on its own —
/// the provider just translates these cases into `NEFilter*` verdicts.
public enum ThrottleVerdict: Equatable {
    /// Let the flow through untouched.
    case allow
    /// Drop the flow (offline / 100% loss).
    case drop
    /// Hold the flow, then resume after `seconds`. This is how bandwidth
    /// and latency are simulated: meter the bytes, release them slowly.
    case pause(seconds: Double)
}

/// Pure throttle math. Given a profile and the running byte count for a
/// flow, decide allow / drop / pause-for-N-seconds.
public struct ThrottleEngine: Equatable {
    public let profile: NetworkProfile

    public init(profile: NetworkProfile) { self.profile = profile }

    /// Verdict for a chunk of `bytes` whose delivery brings the flow's
    /// running total to `totalBytesSoFar`.
    ///
    /// - Offline profile → `.drop`.
    /// - Unlimited + no latency → `.allow`.
    /// - Otherwise pause for `totalBytesSoFar / bandwidth + latency`, the
    ///   time at which this much data "should" have arrived on the
    ///   simulated link. The first chunk also pays the full latency.
    public func verdict(forBytes bytes: Int, totalBytesSoFar: Int) -> ThrottleVerdict {
        if profile.isOffline { return .drop }
        let latencySeconds = Double(profile.latencyMillis) / 1000.0
        if profile.bandwidthInBytes == 0 {
            return latencySeconds > 0 && totalBytesSoFar <= bytes ? .pause(seconds: latencySeconds) : .allow
        }
        let transmitSeconds = Double(totalBytesSoFar) / Double(profile.bandwidthInBytes)
        let delay = transmitSeconds + (totalBytesSoFar <= bytes ? latencySeconds : 0)
        return delay > 0 ? .pause(seconds: delay) : .allow
    }
}

/// Deterministic per-packet drop, given a `0…1` loss fraction. Not
/// statistical — a fixed stride (`0.25` → drop every 4th packet) — so it
/// is reproducible and testable. `index` is a monotonically increasing
/// per-provider packet counter.
public struct PacketLossGate: Equatable {
    public let packetLoss: Double

    public init(packetLoss: Double) { self.packetLoss = min(max(packetLoss, 0), 1) }

    /// True when the packet at `index` should be dropped.
    public func shouldDrop(index: Int) -> Bool {
        guard packetLoss > 0 else { return false }
        if packetLoss >= 1 { return true }
        let stride = Int((1.0 / packetLoss).rounded())
        guard stride > 0 else { return true }
        return index % stride == stride - 1
    }
}
