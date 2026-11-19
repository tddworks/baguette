import Foundation

/// A booted simulator's user-interface appearance style — the setting a
/// user knows as light / dark mode.
///
/// `unknown` and `unsupported` are answers, not failures. A shut-down
/// device prints `unknown` and exits 0, and an old runtime prints
/// `unsupported`; both are honest states a caller should show as "can't
/// tell" rather than guessing `light`. Because they're answers, neither
/// has an `argument` — there is no argv that means "make it unknown".
public enum InterfaceAppearance: String, Equatable, Sendable, CaseIterable {
    case light
    case dark
    /// The runtime or platform has no appearance styles.
    case unsupported
    /// Nothing answered — most often the device isn't booted.
    case unknown

    /// Parse what `simctl ui <udid> appearance` printed. Anything we
    /// don't recognise is `unknown`: a future simctl adding a style
    /// should read as "can't tell" rather than crashing a panel.
    public init(output: String) {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = InterfaceAppearance(rawValue: value) ?? .unknown
    }

    /// The token `simctl ui <udid> appearance <arg>` accepts, or nil for
    /// the two states that can only be read.
    public var argument: String? {
        switch self {
        case .light, .dark: return rawValue
        case .unsupported, .unknown: return nil
        }
    }

    /// The other style — what a toggle switches to. Nil when we don't
    /// know where we're starting from, because "toggle" has no meaning
    /// without a current value.
    public var toggled: InterfaceAppearance? {
        switch self {
        case .light: return .dark
        case .dark: return .light
        case .unsupported, .unknown: return nil
        }
    }
}
