import Foundation

/// Two-finger parallel drag. Both fingers start at given positions and
/// translate by the same `(dx, dy)` over `duration` seconds.
struct Pan: Gesture, Equatable {
    static let wireType = "pan"

    let first: Point
    let second: Point
    let dx: Double
    let dy: Double
    let size: Size
    let duration: Double

    static func parse(_ dict: [String: Any]) throws -> Pan {
        Pan(
            first:  try Field.requiredPoint(dict, "x1", "y1"),
            second: try Field.requiredPoint(dict, "x2", "y2"),
            dx: try Field.requiredDouble(dict, "dx"),
            dy: try Field.requiredDouble(dict, "dy"),
            size: try Field.requiredSize(dict),
            duration: Field.optionalDouble(dict, "duration", default: 0.5)
        )
    }

    func execute(on input: any Input) -> Bool {
        input.twoFingerPath(
            start1: first,
            end1:   Point(x: first.x  + dx, y: first.y  + dy),
            start2: second,
            end2:   Point(x: second.x + dx, y: second.y + dy),
            size: size, duration: duration
        )
    }
}
