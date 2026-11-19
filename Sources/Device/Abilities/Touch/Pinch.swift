import Foundation

/// Two-finger pinch / spread around a centre point. Translates to a pair
/// of synchronised finger paths along the horizontal axis at `(cx, cy)`.
public struct Pinch: Gesture, Equatable {
    public static let wireType = "pinch"

    public let center: Point
    public let startSpread: Double
    public let endSpread: Double
    public let size: Size
    public let duration: Double

    public static func parse(_ dict: [String: Any]) throws -> Pinch {
        Pinch(
            center: try Field.requiredPoint(dict, "cx", "cy"),
            startSpread: try Field.requiredDouble(dict, "startSpread"),
            endSpread:   try Field.requiredDouble(dict, "endSpread"),
            size: try Field.requiredSize(dict),
            duration: Field.optionalDouble(dict, "duration", default: 0.6)
        )
    }

    public static var ability: Ability<any Touch> { .touch }

    public func execute(on touch: any Touch) -> Bool {
        let halfStart = startSpread / 2
        let halfEnd   = endSpread / 2
        return touch.twoFingerPath(
            start1: Point(x: center.x - halfStart, y: center.y),
            end1:   Point(x: center.x - halfEnd,   y: center.y),
            start2: Point(x: center.x + halfStart, y: center.y),
            end2:   Point(x: center.x + halfEnd,   y: center.y),
            size: size, duration: duration
        )
    }

    public init(center: Point, startSpread: Double, endSpread: Double, size: Size, duration: Double) {
        self.center = center
        self.startSpread = startSpread
        self.endSpread = endSpread
        self.size = size
        self.duration = duration
    }
}
