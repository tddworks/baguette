import BaguetteDevice
import Foundation

/// Cadence floor for SimulatorKit screen capture. CarPlay's home
/// screen (and a quiet phone lock screen) often stop delivering
/// frame callbacks; without a floor the browser freezes on black or
/// a stale seed. 5 fps matches the sim_carplay spike idle floor.
enum ScreenIdleFloor {
    static let intervalNanoseconds: UInt64 = 200_000_000

    static func isEnabled(for kind: DisplayKind) -> Bool {
        switch kind {
        case .phone, .carPlay: return true
        }
    }
}
