import Foundation
import Mockable

/// A booted simulator's user-interface settings: appearance style,
/// Increase Contrast, and content size (Dynamic Type).
///
/// One surface because `xcrun simctl ui <udid> …` is one verb family,
/// and because the three travel together in practice — an accessibility
/// pass flips to dark, turns contrast up, and pushes text to an
/// accessibility size, then re-reads the screen.
///
/// Reads never throw for a device that simply can't answer: a shut-down
/// simulator reports `unknown` and exits 0, and that's a state worth
/// showing rather than an error worth raising. Only a spawn that fails
/// throws. The production impl is `SimctlInterface` (Infrastructure).
@Mockable
public protocol Interface: Sendable {
    /// The current appearance style, or `.unknown` when the device
    /// can't say (usually because it isn't booted).
    func appearance() async throws -> InterfaceAppearance
    /// Set light or dark. Throws `InterfaceError.simctlFailed` if the
    /// spawn exits non-zero.
    func setAppearance(_ appearance: InterfaceAppearance) async throws

    /// Whether Increase Contrast is on, or `.unknown`.
    func increaseContrast() async throws -> InterfaceContrast
    func setIncreaseContrast(_ contrast: InterfaceContrast) async throws

    /// The current content size category, or `.unknown`.
    func contentSize() async throws -> ContentSize
    /// Set a category outright, or step one notch with
    /// `.increment` / `.decrement`.
    func setContentSize(_ change: ContentSizeChange) async throws
}

/// Failure modes the interface surface surfaces. Each maps to a CLI
/// exit message / HTTP error body.
public enum InterfaceError: Error, Equatable, CustomStringConvertible {
    /// Asked to set a value that can only be read (`unknown` /
    /// `unsupported`). Caught before the spawn so the message names the
    /// real mistake instead of echoing a simctl usage dump.
    case notSettable(String)
    /// `xcrun simctl ui …` exited non-zero.
    case simctlFailed(status: Int32)

    public var description: String {
        switch self {
        case .notSettable(let value):
            return "\"\(value)\" is a reading, not a setting — it cannot be applied"
        case .simctlFailed(let status):
            return "xcrun simctl ui exited \(status)"
        }
    }
}
