import BaguetteDevice
import Foundation

/// How a pose change ends a command. 3 is documented with the exit codes
/// in `docs/commands.md`.
extension PoseDelivery {
    var exitStatus: Int32 {
        switch self {
        case .delivered: 0
        case .rejected: 1
        case .unconfirmed: 3
        }
    }
}
