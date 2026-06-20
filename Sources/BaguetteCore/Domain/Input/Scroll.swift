import Foundation

/// One scroll-wheel tick. `deltaX` / `deltaY` in points.
struct Scroll: Gesture, Equatable {
    static let wireType = "scroll"

    let deltaX: Double
    let deltaY: Double

    static func parse(_ dict: [String: Any]) throws -> Scroll {
        Scroll(
            deltaX: Field.optionalDouble(dict, "deltaX", default: 0),
            deltaY: Field.optionalDouble(dict, "deltaY", default: 0)
        )
    }

    func execute(on input: any Input) -> Bool {
        input.scroll(deltaX: deltaX, deltaY: deltaY)
    }
}
