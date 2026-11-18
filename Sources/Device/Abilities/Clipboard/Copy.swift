import Foundation

/// Copy the focused field's selection out of the sim onto the host
/// Mac's clipboard. Wire shape: `{ "type": "copy", "press": true }`.
/// The interactive mirror of `Paste`: presses Cmd+C so iOS copies the
/// current selection into the sim's pasteboard, then ferries that
/// pasteboard onto the host (`syncToHost`, full-fidelity — images
/// included). `press: false` skips the keystroke for a pure ferry of
/// whatever the sim already holds.
///
/// Not a `Gesture`: the pasteboard sync is an async host call against
/// `Pasteboard`, which the sync, `Input`-only `Gesture.execute` can't
/// reach. Both wire entry points intercept `copy` lines before the
/// gesture registry (`CopyDispatch`), the same way `paste` is handled.
public struct Copy: Equatable, Sendable {
    public static let wireType = "copy"

    /// Press Cmd+C in the sim before ferrying, so the focused field
    /// copies its selection. `false` ferries the current pasteboard
    /// only (no keystroke).
    public let press: Bool

    /// Beat between the Cmd+C keystroke and reading the pasteboard, so
    /// the focused app has finished populating `UIPasteboard` before
    /// the sync reads it back. Injectable (`0` in tests) so the unit
    /// suite doesn't actually sleep.
    public let settleNanos: UInt64

    /// 200 ms comfortably covers the guest's key-event → `UIPasteboard`
    /// round-trip without a perceptible delay on the interactive path.
    public static let defaultSettleNanos: UInt64 = 200_000_000

    public init(press: Bool = true, settleNanos: UInt64 = Copy.defaultSettleNanos) {
        self.press = press
        self.settleNanos = settleNanos
    }

    public static func parse(_ dict: [String: Any]) -> Copy {
        Copy(press: Field.optionalBool(dict, "press", default: true))
    }

    /// Press Cmd+C (when `press`), let the guest settle, then sync the
    /// sim's pasteboard onto the host. The sync always runs — even a
    /// keystroke the HID layer reports as unaccepted may still have
    /// copied — so the return value carries the keystroke's success
    /// (`true` when `press` is false) while the host clipboard is left
    /// holding the sim's pasteboard regardless.
    public func execute(pasteboard: any Pasteboard, input: Abilities) async throws -> Bool {
        var pressed = true
        if press {
            pressed = KeyboardKey.from(wireCode: "KeyC")!
                .press(modifiers: [.command], on: try input.require(.key))
            if settleNanos > 0 {
                try? await Task.sleep(nanoseconds: settleNanos)
            }
        }
        try await pasteboard.syncToHost()
        return pressed
    }
}
