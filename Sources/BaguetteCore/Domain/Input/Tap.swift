import Foundation

/// Single-finger tap at a point. Default hold duration mirrors a quick
/// human tap (50 ms).
struct Tap: Gesture, Equatable {
    static let wireType = "tap"

    let at: Point
    let size: Size
    let duration: Double

    static func parse(_ dict: [String: Any]) throws -> Tap {
        Tap(
            at: try Field.requiredPoint(dict, "x", "y"),
            size: try Field.requiredSize(dict),
            duration: Field.optionalDouble(dict, "duration", default: 0.05)
        )
    }

    func execute(on input: any Input) -> Bool {
        input.tap(at: at, size: size, duration: duration)
    }
}
