import Foundation

/// The twin envelope, phone side — must mirror the host's
/// `TwinEnvelope` / `AVCCEnvelope` exactly (see
/// `docs/features/device-twin.md`). Text frames are JSON lines;
/// binary frames are `[4-byte big-endian length][tag][payload]`
/// chunks, the same framing baguette's AVCC streams use.
public enum TwinWire {
    public static let descriptionTag: UInt8 = 0x01
    public static let keyframeTag: UInt8 = 0x02
    public static let deltaTag: UInt8 = 0x03

    /// Shared settings suite between app and broadcast extension.
    public static let appGroup = "group.com.tddworks.baguette.twin"
    public static let endpointKey = "twin.endpoint"
    public static let deviceIdKey = "twin.deviceId"

    /// Users paste addresses with schemes and slashes; the wire wants
    /// bare `host:port`. Normalized in one place so the app's saved
    /// value and the extension's URL never disagree.
    public static func normalizedEndpoint(_ raw: String) -> String {
        var endpoint = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["ws://", "wss://", "http://", "https://"]
        where endpoint.lowercased().hasPrefix(prefix) {
            endpoint = String(endpoint.dropFirst(prefix.count))
        }
        while endpoint.hasSuffix("/") { endpoint = String(endpoint.dropLast()) }
        return endpoint
    }

    public static func chunk(tag: UInt8, payload: Data) -> Data {
        let length = UInt32(payload.count + 1)
        var out = Data([
            UInt8((length >> 24) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF),
            tag,
        ])
        out.append(payload)
        return out
    }

    public static func hello(
        udid: String, name: String, model: String, capabilities: [String]
    ) -> String {
        jsonLine([
            "type": "hello",
            "udid": udid,
            "name": name,
            "model": model,
            "capabilities": capabilities,
        ])
    }

    public static func format(
        width: Int, height: Int, orientation: String, codec: String
    ) -> String {
        jsonLine([
            "type": "format",
            "width": width,
            "height": height,
            "orientation": orientation,
            "codec": codec,
        ])
    }

    private static func jsonLine(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
