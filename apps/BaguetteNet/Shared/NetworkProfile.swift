import Foundation

/// The whole feature in three numbers. Shared verbatim between the host
/// app (which writes it to the app group) and the system extension (which
/// reads it back and enforces it). Pure value type — no NetworkExtension
/// imports — so it unit-tests with no entitlement.
///
/// `bandwidthInBytes` is **bytes per second** (0 = unlimited), `latency`
/// is added one-way delay in milliseconds, `packetLoss` is a `0…1`
/// fraction. Out-of-range inputs are clamped on construction so a bad
/// slider value can never make enforcement misbehave.
public struct NetworkProfile: Equatable, Sendable, Codable {
    public var bandwidthInBytes: UInt64
    public var latencyMillis: Int
    public var packetLoss: Double

    public init(bandwidthInBytes: UInt64 = 0, latencyMillis: Int = 0, packetLoss: Double = 0) {
        self.bandwidthInBytes = bandwidthInBytes
        self.latencyMillis = max(0, latencyMillis)
        self.packetLoss = min(max(packetLoss, 0), 1)
    }

    /// No throttle — full speed, no delay, no loss.
    public static let unthrottled = NetworkProfile()

    /// True when there is nothing to enforce (every flow passes untouched).
    public var isUnthrottled: Bool {
        bandwidthInBytes == 0 && latencyMillis == 0 && packetLoss == 0
    }

    /// True when the link is effectively down (drop every flow on sight).
    public var isOffline: Bool { packetLoss >= 1.0 }

    /// Named presets — sugar over the three fields. Bandwidth values are
    /// bytes/s (kbps ÷ 8). The single source of truth for the host app's
    /// preset pills and the CLI `--preset` flag.
    public static let presets: [String: NetworkProfile] = [
        "unlimited": .unthrottled,
        "lte":       NetworkProfile(bandwidthInBytes: 6_500_000, latencyMillis: 60,  packetLoss: 0),
        "3g":        NetworkProfile(bandwidthInBytes: 97_500,    latencyMillis: 300, packetLoss: 0),
        "edge":      NetworkProfile(bandwidthInBytes: 30_000,    latencyMillis: 420, packetLoss: 0.02),
        "loss100":   NetworkProfile(bandwidthInBytes: 0,         latencyMillis: 0,   packetLoss: 1.0),
        "airplane":  NetworkProfile(bandwidthInBytes: 0,         latencyMillis: 0,   packetLoss: 1.0),
    ]
}
