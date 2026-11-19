import Foundation

// MARK: - Wire encoding

public extension NetworkCondition {

    private enum Key: String, CodingKey {
        case bandwidthKbps, latencyMs, lossPercent, offline, pacing
    }

    private enum PacingKey: String, CodingKey {
        case bytesPerTick, tickIntervalMs
    }

    /// Sorted-key JSON, so the bytes are stable and comparable in a test —
    /// the same discipline `MotionIntent.encoded()` holds, and for the same
    /// reason: the dylib parses this with `NSJSONSerialization`, and a field
    /// that quietly changes shape is a condition that quietly stops
    /// applying.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    init(decoding data: Data) throws {
        self = try JSONDecoder().decode(NetworkCondition.self, from: data)
    }
}

extension NetworkCondition: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(latencyMs, forKey: .latencyMs)
        try c.encode(lossPercent, forKey: .lossPercent)
        try c.encode(isOffline, forKey: .offline)
        // Absent rather than zero when unmetered: a zero would have to mean
        // either "unlimited" or "nothing gets through", and the dylib would
        // have to guess which.
        try c.encodeIfPresent(bandwidthKbps, forKey: .bandwidthKbps)
        if let schedule {
            var p = c.nestedContainer(keyedBy: PacingKey.self, forKey: .pacing)
            try p.encode(schedule.bytesPerTick, forKey: .bytesPerTick)
            try p.encode(schedule.tickIntervalMs, forKey: .tickIntervalMs)
        }
    }
}

extension NetworkCondition: Decodable {
    /// `pacing` is deliberately **not** read back — it's derived from
    /// `bandwidthKbps`, so a hand-edited file can't make a condition
    /// disagree with itself about how fast it is.
    ///
    /// Decoding goes through the validating initialiser, because this file
    /// lives on shared `/tmp` and anyone can open it. A condition that
    /// describes no network fails here rather than becoming a throttle
    /// nobody can account for later.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard let condition = NetworkCondition(
            latencyMs: try c.decode(Double.self, forKey: .latencyMs),
            bandwidthKbps: try c.decodeIfPresent(Double.self, forKey: .bandwidthKbps),
            lossPercent: try c.decode(Double.self, forKey: .lossPercent),
            isOffline: try c.decode(Bool.self, forKey: .offline)
        ) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: c.codingPath,
                    debugDescription: "these numbers do not describe a network"))
        }
        self = condition
    }
}
