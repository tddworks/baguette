import Foundation

/// Wire verbs that toggle recording on the live WS stream. Same shape as
/// `ReconfigParser` — one tiny pure function from line to value, so the
/// server's inbound dispatcher stays a flat sequence of try-this-first
/// branches rather than a JSON-parsing layer cake.
///
/// Returns nil for anything that isn't a recording verb so reconfig and
/// gesture dispatch can take their turn unchanged.
enum RecordingControl: Equatable {
    case start
    case stop

    static func parse(_ line: String) -> RecordingControl? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let kind = dict["type"] as? String
        else { return nil }

        switch kind {
        case "start_record": return .start
        case "stop_record":  return .stop
        default:             return nil
        }
    }
}
