import Foundation

/// Typing on a device that has keys: each character its keystroke on the US
/// keyboard (`KeyboardKey.decompose`), Shift where it needs, in order. Text
/// with a character the keyboard can't type is refused whole, before any key.
public struct KeystrokeTyping: Typing {
    /// How long one typed key stays down. A burst needs it short: every character
    /// waits for it, and 20–100 ms all landed every key in 20 runs each. Kept above the
    /// 20 ms floor because `type` has no read-back to catch a dropped key.
    public static let keyHold = 0.03

    private let key: any Key

    public init(key: any Key) { self.key = key }

    public func type(_ text: String) -> Bool {
        guard let strokes = Self.keystrokes(text) else { return false }
        return strokes.allSatisfy { $0.execute(on: key) }
    }

    /// The keystrokes that type `text`, or nil when one character isn't on the keyboard.
    static func keystrokes(_ text: String) -> [Keystroke]? {
        var out: [Keystroke] = []
        out.reserveCapacity(text.count)
        for character in text {
            guard let pair = KeyboardKey.decompose(character: character) else { return nil }
            out.append(Keystroke(key: pair.key, modifiers: pair.modifiers, duration: keyHold))
        }
        return out
    }
}
