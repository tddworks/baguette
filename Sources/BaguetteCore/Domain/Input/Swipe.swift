import Foundation

/// One-finger drag from `from` to `to` over `duration` seconds.
struct Swipe: Gesture, Equatable {
    static let wireType = "swipe"

    let from: Point
    let to: Point
    let size: Size
    let duration: Double

    static func parse(_ dict: [String: Any]) throws -> Swipe {
        Swipe(
            from: try Field.requiredPoint(dict, "startX", "startY"),
            to:   try Field.requiredPoint(dict, "endX", "endY"),
            size: try Field.requiredSize(dict),
            duration: Field.optionalDouble(dict, "duration", default: 0.25)
        )
    }

    func execute(on input: any Input) -> Bool {
        input.swipe(from: from, to: to, size: size, duration: duration)
    }
}
