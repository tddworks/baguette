import Foundation
import Mockable

/// Turning a device on and off — a simulator's boot, an emulator's start.
/// A physical phone never registers it, so `baguette boot` on one is a
/// refusal, not a special case.
@Mockable
protocol Lifecycle: Sendable {
    func boot() throws
    func shutdown() throws
}
