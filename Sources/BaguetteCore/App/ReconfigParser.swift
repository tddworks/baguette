import Foundation

/// Parses one stdin reconfig line and applies it to a `StreamConfig`.
/// Unknown / malformed input returns the input config unchanged — the
/// stream keeps running on whatever was previously in effect.
enum ReconfigParser {
    static func apply(_ line: String, to current: StreamConfig) -> StreamConfig {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let kind = dict["type"] as? String
        else { return current }

        switch kind {
        case "set_bitrate":
            guard let bps = number(dict["bps"]) else { return current }
            return current.with(bitrateBps: Int(bps))
        case "set_fps":
            guard let fps = number(dict["fps"]) else { return current }
            return current.with(fps: Int(fps))
        case "set_scale":
            guard let scale = number(dict["scale"]) else { return current }
            return current.with(scale: Int(scale))
        default:
            return current
        }
    }

    // JSONSerialization wraps every numeric in NSNumber, which always
    // bridges to Double — including JSON integer literals — so a single
    // cast covers every payload shape the wire produces.
    private static func number(_ raw: Any?) -> Double? {
        raw as? Double
    }
}
