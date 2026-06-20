import Foundation

/// One thing the user does to the simulator — `tap`, `swipe`, `button`,
/// etc. Each conforming type carries its own fields (parsed from JSON on
/// the wire) and knows how to dispatch itself against an `Input`.
protocol Gesture: Sendable {
    /// The `"type"` value on the wire that selects this gesture's parser.
    static var wireType: String { get }

    /// Build an instance from the parsed JSON dict. Throws
    /// `GestureError` on missing or malformed fields.
    static func parse(_ dict: [String: Any]) throws -> Self

    /// Run the gesture against the input surface. Returns the surface's
    /// success flag.
    func execute(on input: any Input) -> Bool
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

    static func requiredPhase(_ dict: [String: Any]) throws -> GesturePhase {
        let raw = try requiredString(dict, "phase")
        guard let phase = GesturePhase(rawValue: raw) else {
            throw GestureError.invalidValue("phase", expected: "down | move | up")
        }
        return phase
    }
}
