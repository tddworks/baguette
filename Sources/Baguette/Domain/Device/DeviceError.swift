import Foundation

/// Why a device could not be driven as asked.
enum DeviceError: Error, Equatable {
    /// The device never registered this ability.
    case unable(ability: String, device: String)
    /// No source knows this id.
    case unknown(id: DeviceID)
    /// Two sources claim this id; picking one would be a guess.
    case claimedTwice(id: DeviceID)
    /// The ability acts on a running device, and this one isn't ready.
    case notReady(device: String, state: DeviceState)
}

extension DeviceError: CustomStringConvertible, LocalizedError {
    var errorDescription: String? { description }

    var description: String {
        switch self {
        case let .unable(ability, device): return "\(device) can't do \(ability)"
        case let .unknown(id):             return "Device \(id) not found"
        case let .claimedTwice(id):        return "Device \(id) is claimed by two sources"
        case let .notReady(device, state):
            switch state {
            case .off, .ready:              return "Device \(device) is not booted"
            case .starting:                 return "Device \(device) is still starting"
            case let .unavailable(reason):  return "Device \(device) is unavailable: \(reason)"
            }
        }
    }
}
