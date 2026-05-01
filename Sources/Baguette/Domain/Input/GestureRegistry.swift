import Foundation

/// Routes incoming JSON dicts to the right `Gesture` parser by their
/// `"type"` field. Adding a new gesture is one `register(...)` line; no
/// central switch grows.
///
/// Phased gestures (`Touch1`, `Touch2`) support the `<prefix>-<phase>`
/// shorthand on the wire — `"touch1-down"` resolves to `Touch1` with
/// `phase = .down` injected into the parsed dict.
final class GestureRegistry {
    typealias Parser = ([String: Any]) throws -> any Gesture

    private var parsers: [String: Parser] = [:]
    private var phasedPrefixes: Set<String> = []

    func register<G: Gesture>(_ type: G.Type) {
        parsers[type.wireType] = { dict in try type.parse(dict) }
    }

    /// Registers a gesture whose `wireType` is a prefix; three phase
    /// variants `<prefix>-down`, `<prefix>-move`, `<prefix>-up` all resolve
    /// to the same parser with `phase` injected into the dict.
    func registerPhased<G: Gesture>(_ type: G.Type) {
        register(type)
        phasedPrefixes.insert(type.wireType)
    }

    func parse(_ dict: [String: Any]) throws -> any Gesture {
        let kind = try Field.requiredString(dict, "type")

        if let dashIdx = kind.lastIndex(of: "-"),
           let phase = GesturePhase(rawValue: String(kind[kind.index(after: dashIdx)...]))
        {
            let prefix = String(kind[..<dashIdx])
            if phasedPrefixes.contains(prefix), let parser = parsers[prefix] {
                var enriched = dict
                enriched["phase"] = phase.rawValue
                return try parser(enriched)
            }
        }

        guard let parser = parsers[kind] else {
            throw GestureError.unknownKind(kind)
        }
        return try parser(dict)
    }

    /// Standard registry covering every shipping gesture.
    static var standard: GestureRegistry {
        let r = GestureRegistry()
        r.register(Tap.self)
        r.register(Swipe.self)
        r.register(Press.self)
        r.register(Scroll.self)
        r.register(Pinch.self)
        r.register(Pan.self)
        r.registerPhased(Touch1.self)
        r.registerPhased(Touch2.self)
        return r
    }
}
