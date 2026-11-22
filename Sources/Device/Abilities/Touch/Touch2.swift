import Foundation

/// One streaming two-finger event. The two-finger counterpart to `Touch1`.
public struct Touch2: Gesture, Equatable {
    public static let wireType = "touch2"

    public let phase: GesturePhase

    /// Two fingers moving are a motion; landing and lifting are not.
    public var isMotion: Bool { phase == .move }
    public let first: Point
    public let second: Point
    public let size: Size

    public static func parse(_ dict: [String: Any]) throws -> Touch2 {
        Touch2(
            phase: try Field.requiredPhase(dict),
            first: try Field.requiredPoint(dict, "x1", "y1"),
            second: try Field.requiredPoint(dict, "x2", "y2"),
            size: try Field.requiredSize(dict)
        )
    }

    public static var ability: Ability<any Touch> { .touch }

    public func execute(on touch: any Touch) -> Bool {
        touch.touch2(phase: phase, first: first, second: second, size: size)
    }

    public init(phase: GesturePhase, first: Point, second: Point, size: Size) {
        self.phase = phase
        self.first = first
        self.second = second
        self.size = size
    }
}
