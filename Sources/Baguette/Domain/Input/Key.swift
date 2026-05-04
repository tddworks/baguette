import Foundation

/// One keystroke on the simulator's keyboard surface. Wire shape:
/// `{ "type": "key", "code": "KeyA", "modifiers": ["shift"], "duration": 0.2 }`.
/// `code` is a W3C `KeyboardEvent.code` string so the browser can
/// forward the event verbatim. Modifiers are held for the duration
/// of the keystroke; the adapter brackets them around the key press.
struct Key: Gesture, Equatable {
    static let wireType = "key"

    let key: KeyboardKey
    let modifiers: Set<KeyModifier>
    let duration: Double

    init(key: KeyboardKey, modifiers: Set<KeyModifier> = [], duration: Double = 0) {
        self.key = key
        self.modifiers = modifiers
        self.duration = duration
    }

    static func parse(_ dict: [String: Any]) throws -> Key {
        let code = try Field.requiredString(dict, "code")
        guard let key = KeyboardKey.from(wireCode: code) else {
            throw GestureError.invalidValue(
                "code",
                expected: "W3C KeyboardEvent.code (KeyA-Z, Digit0-9, Enter, Escape, Backspace, Tab, Space, Arrow*, common punctuation)"
            )
        }
        let modifiers = try parseModifiers(dict)
        let duration = Field.optionalDouble(dict, "duration", default: 0)
        return Key(key: key, modifiers: modifiers, duration: duration)
    }

    /// Optional `modifiers: ["shift", "command"]`. Each entry maps
    /// to a `KeyModifier` rawValue; unknown entries fail the parse
    /// rather than silently dropping (typos shouldn't go unnoticed).
    private static func parseModifiers(_ dict: [String: Any]) throws -> Set<KeyModifier> {
        guard let raw = dict["modifiers"] else { return [] }
        guard let names = raw as? [String] else {
            throw GestureError.invalidValue("modifiers", expected: "array of strings")
        }
        var set: Set<KeyModifier> = []
        for name in names {
            guard let m = KeyModifier(rawValue: name) else {
                throw GestureError.invalidValue("modifiers", expected: "shift | control | option | command")
            }
            set.insert(m)
        }
        return set
    }

    func execute(on input: any Input) -> Bool {
        key.press(modifiers: modifiers, duration: duration, on: input)
    }
}
