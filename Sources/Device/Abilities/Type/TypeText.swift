import Foundation

/// Multi-character text input. Wire shape:
/// `{ "type": "type", "text": "hello" }`. One act of the device's `Typing` —
/// keystrokes on a device with keys, a whole string on one that types it at
/// once. Characters outside the US keyboard (non-ASCII, control chars, dead
/// keys) fail the parse rather than silently dropping.
public struct TypeText: Gesture, Equatable {
    public static let wireType = "type"

    public let text: String

    public init(text: String) {
        self.text = text
    }

    /// `nil` when a character isn't on the US keyboard, so the caller goes through `paste`.
    public init?(typeable text: String) {
        guard KeystrokeTyping.keystrokes(text) != nil else { return nil }
        self.init(text: text)
    }

    public static func parse(_ dict: [String: Any]) throws -> TypeText {
        let text = try Field.requiredString(dict, "text")
        guard let typed = TypeText(typeable: text) else {
            throw GestureError.invalidValue(
                "text",
                expected: "ASCII printable characters supported by the US keyboard layout"
            )
        }
        return typed
    }

    public static var ability: Ability<any Typing> { .typing }

    public func execute(on typing: any Typing) -> Bool {
        typing.type(text)
    }
}
