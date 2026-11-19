import Foundation

/// A request to move the hinge: Device Hub's three poses by name, or an
/// angle, swept over a duration.
public struct HingeCommand: Equatable, Sendable {
    public let degrees: Double
    public let duration: TimeInterval

    /// Device Hub's poses, as the guest reads them back.
    public static let poses: [String: Double] = ["closed": 0, "open": 130, "flat": 180]
    /// Device Hub's own sweep: 0.5–0.85 s, ease-out.
    public static let defaultDuration: TimeInterval = 0.8
    /// The longest sweep accepted. Device Hub's take under a second, and a
    /// long enough one overflows the millisecond and frame counts the
    /// guest helper is sent.
    public static let maximumDuration: TimeInterval = 60

    public static func parse(pose: String?, angle: String?, duration: String?) throws -> HingeCommand {
        let degrees: Double
        if let pose {
            guard let known = poses[pose] else { throw HingeCommandError.unknownPose(pose) }
            degrees = known
        } else if let angle {
            guard let value = Double(angle), value.isFinite else { throw HingeCommandError.angleOutOfRange }
            guard (0...180).contains(value) else { throw HingeCommandError.angleOutOfRange }
            degrees = value
        } else {
            throw HingeCommandError.missingTarget
        }
        var seconds = defaultDuration
        if let duration {
            guard let value = Double(duration), (0...maximumDuration).contains(value) else {
                throw HingeCommandError.invalidDuration
            }
            seconds = value
        }
        return HingeCommand(degrees: degrees, duration: seconds)
    }

    public init(degrees: Double, duration: TimeInterval) {
        self.degrees = degrees
        self.duration = duration
    }
}

public enum HingeCommandError: Error, Equatable {
    case missingTarget
    case unknownPose(String)
    case angleOutOfRange
    case invalidDuration
}
