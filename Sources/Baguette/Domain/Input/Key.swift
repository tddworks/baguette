import Foundation
import Mockable

/// The device's keyboard: one key at a time, with modifiers held around
/// it (each modifier down → key down → hold → key up → modifiers up).
/// US-ASCII only — HID page 7.
@Mockable
protocol Key: Sendable {
    /// Prefer `key.press(modifiers:duration:on:)`.
    func key(_ key: KeyboardKey, modifiers: Set<KeyModifier>, duration: Double) -> Bool
}
