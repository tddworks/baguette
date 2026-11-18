import BaguetteDevice
import Foundation

/// One turn of the scroll wheel, as a browser's `WheelEvent` carries it:
/// `deltaX` / `deltaY` in points.
struct WheelEvent: Gesture, Equatable {
    static let wireType = "scroll"

    let deltaX: Double
    let deltaY: Double

    static func parse(_ dict: [String: Any]) throws -> WheelEvent {
        WheelEvent(
            deltaX: Field.optionalDouble(dict, "deltaX", default: 0),
            deltaY: Field.optionalDouble(dict, "deltaY", default: 0)
        )
    }

    static var ability: Ability<any Scroll> { .scroll }

    func execute(on scroll: any Scroll) -> Bool {
        scroll.scroll(deltaX: deltaX, deltaY: deltaY)
    }
}
