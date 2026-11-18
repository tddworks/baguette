import Foundation
import Mockable

/// What moves a foldable's hinge — and turns the device — the way Device
/// Hub's pose picker and rotate button do. The production impl is
/// `GuestHingeMotor`, which runs `HingeControl` inside the guest.
@Mockable
public protocol HingeMotor: Sendable {
    /// Sweep the hinge from one angle to another over `duration` seconds,
    /// at 60 Hz with an ease-out, as Device Hub's picker plays a pose
    /// change. Returns when the sweep has been delivered.
    func fold(from: Double, to: Double, over duration: TimeInterval) throws

    /// Turn the device to a physical orientation through the same
    /// channel Device Hub's rotate button uses. Returns when the guest
    /// has dispatched it.
    func turn(to orientation: DeviceOrientation) throws
}

public enum HingeError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The build did not ship `HingeControl`, or it could not be installed.
    case toolMissing
    case toolFailed(status: Int32)
    case toolTimedOut
    /// The helper started after its deadline and did nothing.
    case toolStartedLate
}

public extension HingeError {
    var description: String {
        switch self {
        case .toolMissing: "HingeControl is missing or could not be installed."
        case .toolFailed(let status): "HingeControl exited with status \(status)."
        case .toolTimedOut: "HingeControl did not answer in time; the command may have been delivered, but the stopped helper cannot deliver it later."
        case .toolStartedLate: "HingeControl started after its deadline and did nothing; the command was not delivered."
        }
    }

    var errorDescription: String? { description }
}
