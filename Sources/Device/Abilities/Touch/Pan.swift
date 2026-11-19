import Foundation

/// Two-finger parallel drag. Both fingers start at given positions and
/// translate by the same `(dx, dy)` over `duration` seconds.
public struct Pan: Gesture, Equatable {
    public static let wireType = "pan"

    public let first: Point
    public let second: Point
    public let dx: Double
    public let dy: Double
    public let size: Size
    public let duration: Double

    public static func parse(_ dict: [String: Any]) throws -> Pan {
        Pan(
            first:  try Field.requiredPoint(dict, "x1", "y1"),
            second: try Field.requiredPoint(dict, "x2", "y2"),
            dx: try Field.requiredDouble(dict, "dx"),
            dy: try Field.requiredDouble(dict, "dy"),
            size: try Field.requiredSize(dict),
            duration: Field.optionalDouble(dict, "duration", default: 0.5)
        )
    }

    public static var ability: Ability<any Touch> { .touch }

    public func execute(on touch: any Touch) -> Bool {
        touch.twoFingerPath(
            start1: first,
            end1:   Point(x: first.x  + dx, y: first.y  + dy),
            start2: second,
            end2:   Point(x: second.x + dx, y: second.y + dy),
            size: size, duration: duration
        )
    }

    public init(first: Point, second: Point, dx: Double, dy: Double, size: Size, duration: Double) {
        self.first = first
        self.second = second
        self.dx = dx
        self.dy = dy
        self.size = size
        self.duration = duration
    }
}
