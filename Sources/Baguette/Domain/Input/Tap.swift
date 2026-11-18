import Foundation

/// Single-finger tap at a point. Default hold duration mirrors a quick
/// human tap (50 ms).
///
/// `edge` names the screen edge the finger lands on, the same hint
/// `Touch1` carries. It is the one thing a streamed touch could say
/// and a one-shot tap could not, which is why a browser touch on a
/// CarPlay nav-bar button worked while the identical wire `tap` was
/// swallowed — see `docs/features/touches/README.md`.
struct Tap: Gesture, Equatable {
    static let wireType = "tap"

    let at: Point
    let size: Size
    let duration: Double
    let edge: DeviceEdge?

    init(at: Point, size: Size, duration: Double, edge: DeviceEdge? = nil) {
        self.at = at
        self.size = size
        self.duration = duration
        self.edge = edge
    }

    static func parse(_ dict: [String: Any]) throws -> Tap {
        Tap(
            at: try Field.requiredPoint(dict, "x", "y"),
            size: try Field.requiredSize(dict),
            duration: Field.optionalDouble(dict, "duration", default: 0.05),
            edge: try Field.optionalEdge(dict)
        )
    }

    static var ability: Ability<any Touch> { .touch }

    func execute(on touch: any Touch) -> Bool {
        touch.tap(at: at, size: size, duration: duration, edge: edge)
    }
}
