import Foundation
import Mockable

/// The device's scroll wheel: a delta in points, as a browser's
/// `WheelEvent` carries it.
@Mockable
protocol Scroll: Sendable {
    func scroll(deltaX: Double, deltaY: Double) -> Bool
}
