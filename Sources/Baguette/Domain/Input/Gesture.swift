import Foundation

/// One thing the user does to a device — a tap, a swipe, a keystroke, a
/// button press. Each is an act of one input ability, which it names: it
/// carries its own fields (parsed from JSON on the wire) and runs itself
/// on that ability's role.
protocol Gesture: Sendable {
    /// The input role this act is performed with.
    associatedtype Role

    /// The ability this act needs; a screen without it refuses the act.
    static var ability: Ability<Role> { get }

    /// The `"type"` value on the wire that selects this gesture's parser.
    static var wireType: String { get }

    /// Build an instance from the parsed JSON dict. Throws
    /// `GestureError` on missing or malformed fields.
    static func parse(_ dict: [String: Any]) throws -> Self

    /// Run the act on its role. Returns the role's success flag.
    func execute(on role: Role) -> Bool

    /// What this act needs that `role` doesn't offer — a navigation the
    /// device lacks — or nil when it can act.
    func missing(from role: Role) -> String?
}

extension Gesture {
    func missing(from role: Role) -> String? { nil }

    /// Run the act on the screen's input: the role it needs, or a refusal
    /// naming what is missing and the device.
    func execute(on input: Abilities) throws -> Bool {
        let role = try input.require(Self.ability)
        if let missing = missing(from: role) { throw input.refusal(missing) }
        return execute(on: role)
    }
}

/// Failure modes the gesture parsing surfaces. The dispatch layer turns
/// these into ack JSON for the caller.
enum GestureError: Error, Equatable {
    case missingField(String)
    case invalidValue(String, expected: String)
    case unknownKind(String)

    var message: String {
        switch self {
        case .missingField(let field):       return "missing field: \(field)"
        case .invalidValue(let f, let e):    return "invalid \(f): expected \(e)"
        case .unknownKind(let kind):         return "unknown kind: \(kind)"
        }
    }
}

/// Numeric / point / size extractors used by every gesture's parser.
/// `JSONSerialization` yields `Int` for integer literals and `Double`
/// otherwise — both are accepted.
enum Field {
    static func requiredDouble(_ dict: [String: Any], _ key: String) throws -> Double {
        guard let raw = dict[key] else { throw GestureError.missingField(key) }
        if let v = raw as? Double { return v }
        if let v = raw as? Int    { return Double(v) }
        throw GestureError.invalidValue(key, expected: "number")
    }

    static func optionalDouble(_ dict: [String: Any], _ key: String, default fallback: Double) -> Double {
        if let v = dict[key] as? Double { return v }
        if let v = dict[key] as? Int    { return Double(v) }
        return fallback
    }

    static func optionalBool(_ dict: [String: Any], _ key: String, default fallback: Bool) -> Bool {
        (dict[key] as? Bool) ?? fallback
    }

    static func requiredString(_ dict: [String: Any], _ key: String) throws -> String {
        guard let raw = dict[key] else { throw GestureError.missingField(key) }
        guard let v = raw as? String else { throw GestureError.invalidValue(key, expected: "string") }
        return v
    }

    static func requiredPoint(_ dict: [String: Any], _ xKey: String, _ yKey: String) throws -> Point {
        Point(x: try requiredDouble(dict, xKey), y: try requiredDouble(dict, yKey))
    }

    static func requiredSize(_ dict: [String: Any]) throws -> Size {
        Size(width: try requiredDouble(dict, "width"), height: try requiredDouble(dict, "height"))
    }

    /// Absent means an interior touch. Present but unrecognised is an
    /// error, not a quiet demotion to interior — a typo would otherwise
    /// reproduce the very swallowed-tap the hint exists to cure.
    static func optionalEdge(_ dict: [String: Any]) throws -> DeviceEdge? {
        guard let raw = dict["edge"] else { return nil }
        guard let text = raw as? String, let edge = DeviceEdge(rawValue: text) else {
            throw GestureError.invalidValue("edge", expected: DeviceEdge.allowed)
        }
        return edge
    }

    static func requiredPhase(_ dict: [String: Any]) throws -> GesturePhase {
        let raw = try requiredString(dict, "phase")
        guard let phase = GesturePhase(rawValue: raw) else {
            throw GestureError.invalidValue("phase", expected: "down | move | up")
        }
        return phase
    }
}
