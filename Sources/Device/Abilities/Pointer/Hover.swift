import Foundation

/// The pointer moving over the screen with no button down:
/// `{"type":"hover","x","y","width","height"}`, in device points. A motion —
/// a newer hover replaces one still waiting (`PendingGestures`).
public struct Hover: Gesture, Equatable {
    public static let wireType = "hover"

    public let at: Point
    public let size: Size

    public init(at: Point, size: Size) {
        self.at = at
        self.size = size
    }

    public static func parse(_ dict: [String: Any]) throws -> Hover {
        Hover(at: try Field.requiredPoint(dict, "x", "y"), size: try Field.requiredSize(dict))
    }

    public static var ability: Ability<any Pointer> { .pointer }

    public var isMotion: Bool { true }

    public func execute(on pointer: any Pointer) -> Bool {
        pointer.move(to: at, size: size)
    }
}
