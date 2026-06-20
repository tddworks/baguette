import Foundation

/// One streaming touch event — the streaming counterpart to `Tap`. Lets
/// the caller send `down`, many `move`s, then `up` in real time.
///
/// Three wire types map to one struct via the `phase`:
///   `touch1-down`, `touch1-move`, `touch1-up`.
struct Touch1: Gesture, Equatable {
    static let wireType = "touch1"

    let phase: GesturePhase
    let at: Point
    let size: Size
    let edge: DeviceEdge?

    init(phase: GesturePhase, at: Point, size: Size, edge: DeviceEdge? = nil) {
        self.phase = phase
        self.at = at
        self.size = size
        self.edge = edge
    }

    static func parse(_ dict: [String: Any]) throws -> Touch1 {
        Touch1(
            phase: try Field.requiredPhase(dict),
            at: try Field.requiredPoint(dict, "x", "y"),
            size: try Field.requiredSize(dict),
            edge: (dict["edge"] as? String).flatMap(DeviceEdge.init(rawValue:))
        )
    }

    func execute(on input: any Input) -> Bool {
        input.touch1(phase: phase, at: at, size: size, edge: edge)
    }
}
