import Foundation

extension SimulatorState {
    /// A simulator's state in the words every device family shares.
    var deviceState: DeviceState {
        switch self {
        case .booted:                   return .ready
        case .creating, .booting:       return .starting
        case .shutdown, .shuttingDown:  return .off
        }
    }
}
