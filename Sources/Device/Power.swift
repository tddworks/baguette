import Foundation
import Mockable

/// A device's power: turning it on and off — a simulator's boot, an
/// emulator's start. A physical phone never registers it, so `baguette boot`
/// on one is a refusal, not a special case.
@Mockable
public protocol Power: Sendable {
    func turnOn() throws
    func turnOff() throws
}
