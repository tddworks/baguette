import Foundation

/// One inbound WS message on `/simulators/:udid/camera`. Pure value
/// — parses straight off the decoded JSON dict, ignoring transport
/// concerns. The Server route closure switches on this and drives
/// the `CameraSession`.
enum CameraMessage: Equatable {
    case list
    case start(deviceUID: String, flags: CameraFlags)
    case stop
    case setFlags(CameraFlags)

    static func parse(_ json: [String: Any]) throws -> CameraMessage {
        guard let type = json["type"] as? String else {
            throw CameraMessageError.missingType
        }
        switch type {
        case "camera_list":
            return .list
        case "camera_start":
            guard let uid = json["deviceUID"] as? String else {
                throw CameraMessageError.missingField("deviceUID")
            }
            return .start(deviceUID: uid, flags: parseFlags(json))
        case "camera_stop":
            return .stop
        case "camera_set_flags":
            return .setFlags(parseFlags(json))
        default:
            throw CameraMessageError.unknownType(type)
        }
    }

    private static func parseFlags(_ json: [String: Any]) -> CameraFlags {
        let fit = json["fit"] as? String
        let mirror = json["mirror"] as? Bool ?? false
        return CameraFlags(fillGravity: fit == "fill", mirror: mirror)
    }
}

enum CameraMessageError: Error, Equatable, CustomStringConvertible {
    case missingType
    case missingField(String)
    case unknownType(String)

    var description: String {
        switch self {
        case .missingType: return "camera message: missing 'type'"
        case .missingField(let f): return "camera message: missing field '\(f)'"
        case .unknownType(let t): return "camera message: unknown type '\(t)'"
        }
    }
}
