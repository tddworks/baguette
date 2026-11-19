import Foundation

/// Parses one stdin reconfig line and applies it to a `StreamConfig`.
/// Unknown / malformed input returns the input config unchanged — the
/// stream keeps running on whatever was previously in effect.
public enum ReconfigParser {
    public static func apply(_ line: String, to current: StreamConfig) -> StreamConfig {
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

    /// Whether a line addresses the stream encoder rather than the device:
    /// a retune or a keyframe/snapshot request. Routes that run on a
    /// fixed encoder preset reject these instead of acknowledging them.
    public static func isStreamControl(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let kind = dict["type"] as? String
        else { return false }
        return ["set_bitrate", "set_fps", "set_scale", "force_idr", "snapshot"].contains(kind)
    }

    // JSONSerialization wraps every numeric in NSNumber, which always
    // bridges to Double — including JSON integer literals — so a single
    // cast covers every payload shape the wire produces.
    private static func number(_ raw: Any?) -> Double? {
        raw as? Double
    }
}
