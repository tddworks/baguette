import BaguetteDevice
import Foundation

/// Device Hub's pose picker, on the page: `{"type":"set_pose","hingeDegrees":130}`
/// on the 3D socket, beside `set_3d_camera`, moves the device's hinge
/// there (`Hinge.fold`); the book plays the sweep as it goes. The
/// picker leaves `duration` out and gets Device Hub's sweep; the hinge
/// slider sends `"duration":0` to put the hinge where the thumb is.
/// A pose off the hinge is refused as `POST /hinge` refuses it
/// (`HingeCommandError`), so the page can be told what was wrong.
enum Device3DPose: Equatable, Sendable {
    case fold(hingeDegrees: Double, duration: TimeInterval?)

    static func parsing(json: Data) throws -> Device3DPose? {
        let object: [String: Any]
        do {
            object = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        } catch {
            throw DeviceModelError.invalidRenderOptions
        }
        guard object["type"] as? String == "set_pose" else { return nil }
        let degrees: Double?
        if let d = object["hingeDegrees"] as? Double { degrees = d }
        else if let i = object["hingeDegrees"] as? Int { degrees = Double(i) }
        else { degrees = nil }
        guard let degrees, (0...180).contains(degrees) else {
            throw HingeCommandError.angleOutOfRange
        }
        var duration: TimeInterval?
        if let raw = object["duration"] {
            guard let seconds = (raw as? Double) ?? (raw as? Int).map(Double.init),
                  (0...HingeCommand.maximumDuration).contains(seconds)
            else { throw HingeCommandError.invalidDuration }
            duration = seconds
        }
        return .fold(hingeDegrees: degrees, duration: duration)
    }
}

/// The pose a foldable's book is shown at: the hinge's own angle.
struct FoldablePose: Equatable, Sendable {
    let hingeDegrees: Double
}
