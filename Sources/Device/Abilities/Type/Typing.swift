import Foundation
import Mockable

/// Text typed into whatever has focus — the `type` a person writes. A device
/// with keys types by keystrokes (`KeystrokeTyping`); one that can type a
/// whole string at once does (Android's `input text`). US-ASCII only, as the
/// `TypeText` act checks; anything else goes through `paste`.
/// (Named `Typing`: Swift reserves `Type`.)
@Mockable
public protocol Typing: Sendable {
    func type(_ text: String) -> Bool
}

public extension Ability where Role == any Typing {
    static var typing: Self { .init(name: "type", needsReady: true) }
}
