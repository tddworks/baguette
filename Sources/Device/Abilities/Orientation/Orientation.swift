import Foundation
import Mockable

/// Drive a booted simulator's physical orientation. The foreground app
/// still chooses its interface orientation, which can differ.
@Mockable
public protocol Orientation: Sendable {
    /// Reports whether the change was delivered, not whether the app rotated.
    func set(_ orientation: DeviceOrientation) -> PoseDelivery
}
