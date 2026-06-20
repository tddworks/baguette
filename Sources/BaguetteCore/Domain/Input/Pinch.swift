import Foundation

/// Two-finger pinch / spread around a centre point. Translates to a pair
/// of synchronised finger paths along the horizontal axis at `(cx, cy)`.
struct Pinch: Gesture, Equatable {
    static let wireType = "pinch"

    let center: Point
    let startSpread: Double
    let endSpread: Double
    let size: Size
    let duration: Double

    static func parse(_ dict: [String: Any]) throws -> Pinch {
        Pinch(
            center: try Field.requiredPoint(dict, "cx", "cy"),
            startSpread: try Field.requiredDouble(dict, "startSpread"),
            endSpread:   try Field.requiredDouble(dict, "endSpread"),
            size: try Field.requiredSize(dict),
            duration: Field.optionalDouble(dict, "duration", default: 0.6)
        )
    }

    func execute(on input: any Input) -> Bool {
        let halfStart = startSpread / 2
        let halfEnd   = endSpread / 2
        return input.twoFingerPath(
            start1: Point(x: center.x - halfStart, y: center.y),
            end1:   Point(x: center.x - halfEnd,   y: center.y),
            start2: Point(x: center.x + halfStart, y: center.y),
            end2:   Point(x: center.x + halfEnd,   y: center.y),
            size: size, duration: duration
        )
    }
}
