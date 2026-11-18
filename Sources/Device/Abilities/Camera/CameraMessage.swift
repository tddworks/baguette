import Foundation

/// One inbound WS message on `/simulators/:udid/camera`. Pure value
/// — parses straight off the decoded JSON dict, ignoring transport
/// concerns. The Server route closure switches on this and drives
/// the `CameraSession`.
/// Which producer a `camera_start` selects. The webcam carries its
/// `deviceUID`; the file kinds carry nothing — the server resolves the
/// staged host file from its own per-udid registry, so the browser
/// never hands a filesystem path across the wire.
public enum CameraStartSource: Equatable, Sendable {
    case webcam(deviceUID: String)
    case image
    case video
}

public enum CameraMessage: Equatable {
    case list
    case start(source: CameraStartSource, flags: CameraFlags)
    case stop
    case setFlags(CameraFlags)

    public static func parse(_ json: [String: Any]) throws -> CameraMessage {
        guard let type = json["type"] as? String else {
            throw CameraMessageError.missingType
        }
        switch type {
        case "camera_list":
            return .list
        case "camera_start":
            return .start(source: try parseStartSource(json), flags: parseFlags(json))
        case "camera_stop":
            return .stop
        case "camera_set_flags":
            return .setFlags(parseFlags(json))
        default:
            throw CameraMessageError.unknownType(type)
        }
    }

    /// A missing `source` defaults to `"webcam"` for backward
    /// compatibility with clients that only send `deviceUID`.
    private static func parseStartSource(_ json: [String: Any]) throws -> CameraStartSource {
        switch json["source"] as? String ?? "webcam" {
        case "webcam":
            guard let uid = json["deviceUID"] as? String else {
                throw CameraMessageError.missingField("deviceUID")
            }
            return .webcam(deviceUID: uid)
        case "image":
            return .image
        case "video":
            return .video
        case let other:
            throw CameraMessageError.unknownType(other)
        }
    }

    private static func parseFlags(_ json: [String: Any]) -> CameraFlags {
        let fit = json["fit"] as? String
        let mirror = json["mirror"] as? Bool ?? false
        return CameraFlags(fillGravity: fit == "fill", mirror: mirror)
    }
}

public enum CameraMessageError: Error, Equatable, CustomStringConvertible {
    case missingType
    case missingField(String)
    case unknownType(String)

    public var description: String {
        switch self {
        case .missingType: return "camera message: missing 'type'"
        case .missingField(let f): return "camera message: missing field '\(f)'"
        case .unknownType(let t): return "camera message: unknown type '\(t)'"
        }
    }
}
