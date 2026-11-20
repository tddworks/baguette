import Foundation

/// Parses one stdin reconfig line and applies it to a `StreamConfig`.
/// Unknown / malformed input returns the input config unchanged — the
/// stream keeps running on whatever was previously in effect.
public enum ReconfigParser {
    public static func apply(_ line: String, to current: StreamConfig) -> StreamConfig {
        change(line)?.applied(to: current) ?? current
    }

    /// The knob a retune line turns, or nil for anything else (malformed,
    /// missing its number, or not a retune). A running stream takes it with
    /// `update`, against its config as it stands then.
    public static func change(_ line: String) -> StreamConfig.Change? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let kind = dict["type"] as? String
        else { return nil }

        switch kind {
        case "set_bitrate": return number(dict["bps"]).map { .bitrate(Int($0)) }
        case "set_fps": return number(dict["fps"]).map { .fps(Int($0)) }
        case "set_scale": return number(dict["scale"]).map { .scale(Int($0)) }
        default: return nil
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
