import Foundation

/// One streaming touch event — the streaming counterpart to `Tap`. Lets
/// the caller send `down`, many `move`s, then `up` in real time.
///
/// Three wire types map to one struct via the `phase`:
///   `touch1-down`, `touch1-move`, `touch1-up`.
public struct Touch1: Gesture, Equatable {
    public static let wireType = "touch1"

    public let phase: GesturePhase
    public let at: Point
    public let size: Size
    public let edge: DeviceEdge?

    public init(phase: GesturePhase, at: Point, size: Size, edge: DeviceEdge? = nil) {
        self.phase = phase
        self.at = at
        self.size = size
        self.edge = edge
    }

    public static func parse(_ dict: [String: Any]) throws -> Touch1 {
        Touch1(
            phase: try Field.requiredPhase(dict),
            at: try Field.requiredPoint(dict, "x", "y"),
            size: try Field.requiredSize(dict),
            edge: try Field.optionalEdge(dict)
        )
    }

    public static var ability: Ability<any Touch> { .touch }

    public func execute(on touch: any Touch) -> Bool {
        touch.touch1(phase: phase, at: at, size: size, edge: edge)
    }
}
