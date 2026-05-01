import Foundation

/// One streaming two-finger event. The two-finger counterpart to `Touch1`.
struct Touch2: Gesture, Equatable {
    static let wireType = "touch2"

    let phase: GesturePhase
    let first: Point
    let second: Point
    let size: Size

    static func parse(_ dict: [String: Any]) throws -> Touch2 {
        Touch2(
            phase: try Field.requiredPhase(dict),
            first: try Field.requiredPoint(dict, "x1", "y1"),
            second: try Field.requiredPoint(dict, "x2", "y2"),
            size: try Field.requiredSize(dict)
        )
    }

    func execute(on input: any Input) -> Bool {
        input.touch2(phase: phase, first: first, second: second, size: size)
    }
}
