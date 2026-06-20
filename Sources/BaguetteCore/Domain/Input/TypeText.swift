import Foundation

/// Multi-character text input. Wire shape:
/// `{ "type": "type", "text": "hello" }`. Sugar over a sequence of
/// `Key` presses — at parse time we decompose every character on
/// the US-layout keyboard to `(KeyboardKey, modifiers)` pairs;
/// `execute` then dispatches them in order. Characters outside the
/// supported surface (non-ASCII, control chars, dead keys) fail the
/// parse rather than silently dropping.
struct TypeText: Gesture, Equatable {
    static let wireType = "type"

    let text: String
    /// Pre-decomposed keystrokes; storing them lets `parse` reject
    /// unsupported text up front and lets `execute` stay loop-free
    /// of decode logic.
    fileprivate let keystrokes: [Keystroke]

    init(text: String) {
        self.text = text
        // Force-decomposed for the value-init form — the public
        // parser handles errors. Used in tests with known-safe text.
        self.keystrokes = Self.tryDecompose(text) ?? []
    }

    static func parse(_ dict: [String: Any]) throws -> TypeText {
        let text = try Field.requiredString(dict, "text")
        guard let strokes = tryDecompose(text) else {
            throw GestureError.invalidValue(
                "text",
                expected: "ASCII printable characters supported by the US keyboard layout"
            )
        }
        return TypeText(text: text, keystrokes: strokes)
    }

    func execute(on input: any Input) -> Bool {
        for s in keystrokes {
            if !s.key.press(modifiers: s.modifiers, on: input) {
                return false
            }
        }
        return true
    }

    // MARK: - private

    fileprivate init(text: String, keystrokes: [Keystroke]) {
        self.text = text
        self.keystrokes = keystrokes
    }

    fileprivate static func tryDecompose(_ text: String) -> [Keystroke]? {
        var out: [Keystroke] = []
        out.reserveCapacity(text.count)
        for c in text {
            guard let pair = KeyboardKey.decompose(character: c) else { return nil }
            out.append(Keystroke(key: pair.key, modifiers: pair.modifiers))
        }
        return out
    }
}

fileprivate struct Keystroke: Equatable {
    let key: KeyboardKey
    let modifiers: Set<KeyModifier>
}
