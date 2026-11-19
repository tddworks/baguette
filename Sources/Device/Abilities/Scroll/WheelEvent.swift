import Foundation

/// One turn of the scroll wheel, as a browser's `WheelEvent` carries it:
/// `deltaX` / `deltaY` in points.
public struct WheelEvent: Gesture, Equatable {
    public static let wireType = "scroll"

    public let deltaX: Double
    public let deltaY: Double

    public static func parse(_ dict: [String: Any]) throws -> WheelEvent {
        WheelEvent(
            deltaX: Field.optionalDouble(dict, "deltaX", default: 0),
            deltaY: Field.optionalDouble(dict, "deltaY", default: 0)
        )
    }

    public static var ability: Ability<any Scroll> { .scroll }

    public func execute(on scroll: any Scroll) -> Bool {
        scroll.scroll(deltaX: deltaX, deltaY: deltaY)
    }

    public init(deltaX: Double, deltaY: Double) {
        self.deltaX = deltaX
        self.deltaY = deltaY
    }
}
