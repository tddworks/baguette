import Foundation

/// One-finger drag from `from` to `to` over `duration` seconds.
public struct Swipe: Gesture, Equatable {
    public static let wireType = "swipe"

    public let from: Point
    public let to: Point
    public let size: Size
    public let duration: Double

    public static func parse(_ dict: [String: Any]) throws -> Swipe {
        Swipe(
            from: try Field.requiredPoint(dict, "startX", "startY"),
            to:   try Field.requiredPoint(dict, "endX", "endY"),
            size: try Field.requiredSize(dict),
            duration: Field.optionalDouble(dict, "duration", default: 0.25)
        )
    }

    public static var ability: Ability<any Touch> { .touch }

    public func execute(on touch: any Touch) -> Bool {
        touch.swipe(from: from, to: to, size: size, duration: duration)
    }

    public init(from: Point, to: Point, size: Size, duration: Double) {
        self.from = from
        self.to = to
        self.size = size
        self.duration = duration
    }
}
