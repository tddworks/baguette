import Foundation

/// Multi-character text input. Wire shape:
/// `{ "type": "type", "text": "hello" }`. Sugar over a sequence of
/// `Keystroke`s — at parse time we decompose every character on
/// the US-layout keyboard to `(KeyboardKey, modifiers)` pairs;
/// `execute` then dispatches them in order. Characters outside the
/// supported surface (non-ASCII, control chars, dead keys) fail the
/// parse rather than silently dropping.
struct TypeText: Gesture, Equatable {
    static let wireType = "type"

    /// How long one typed key stays down. A burst needs it short: every character
    /// waits for it, and 20–100 ms all landed every key in 20 runs each. Kept above the
    /// 20 ms floor because `type` has no read-back to catch a dropped key.
    static let keyHold = 0.03

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

    /// `nil` when a character isn't on the US keyboard, so the caller goes through `paste`.
    init?(typeable text: String) {
        guard let strokes = Self.tryDecompose(text) else { return nil }
        self.init(text: text, keystrokes: strokes)
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

    static var ability: Ability<any Key> { .key }

    func execute(on keyboard: any Key) -> Bool {
        keystrokes.allSatisfy { $0.execute(on: keyboard) }
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
            out.append(Keystroke(key: pair.key, modifiers: pair.modifiers, duration: keyHold))
        }
        return out
    }
}

