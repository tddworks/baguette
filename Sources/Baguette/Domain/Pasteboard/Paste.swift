import Foundation

/// Paste text into the frontmost app. Wire shape:
/// `{ "type": "paste", "text": "…", "press": true }`. Sets the
/// simulator's pasteboard, then presses Cmd+V so iOS pastes it —
/// the arbitrary-unicode path that `type`'s US-ASCII keystroke
/// decomposition can't cover. `press: false` stops after the
/// pasteboard set, for apps that read `UIPasteboard` directly.
///
/// Not a `Gesture`: setting the pasteboard is an async host call
/// against `Pasteboard`, which the sync, `Input`-only
/// `Gesture.execute` can't reach. Both wire entry points intercept
/// `paste` lines before the gesture registry (`PasteDispatch`),
/// the same way `describe_ui` is handled.
struct Paste: Equatable, Sendable {
    static let wireType = "paste"

    let text: String
    let press: Bool

    init(text: String, press: Bool = true) {
        self.text = text
        self.press = press
    }

    static func parse(_ dict: [String: Any]) throws -> Paste {
        Paste(
            text: try Field.requiredString(dict, "text"),
            press: Field.optionalBool(dict, "press", default: true)
        )
    }

    /// Set the pasteboard, then (when `press`) Cmd+V. Throws the
    /// pasteboard's failure before any keystroke is sent; returns
    /// the key press's success flag (`true` when `press` is false).
    func execute(pasteboard: any Pasteboard, input: Abilities) async throws -> Bool {
        try await pasteboard.setText(text)
        guard press else { return true }
        return KeyboardKey.from(wireCode: "KeyV")!
            .press(modifiers: [.command], on: try input.require(.key))
    }
}
