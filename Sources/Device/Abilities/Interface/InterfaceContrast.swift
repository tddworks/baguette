import Foundation

/// Whether the simulator is running with Increase Contrast on — the
/// accessibility setting that darkens borders and drops translucency.
///
/// Same shape as `InterfaceAppearance`: two real states plus the two
/// non-answers simctl gives for a device that can't say.
public enum InterfaceContrast: String, Equatable, Sendable, CaseIterable {
    case enabled
    case disabled
    /// The runtime or platform has no Increase Contrast setting.
    case unsupported
    /// Nothing answered — most often the device isn't booted.
    case unknown

    public init(output: String) {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = InterfaceContrast(rawValue: value) ?? .unknown
    }

    /// The token `simctl ui <udid> increase_contrast <arg>` accepts, or
    /// nil for the read-only states.
    public var argument: String? {
        switch self {
        case .enabled, .disabled: return rawValue
        case .unsupported, .unknown: return nil
        }
    }

    public var toggled: InterfaceContrast? {
        switch self {
        case .enabled: return .disabled
        case .disabled: return .enabled
        case .unsupported, .unknown: return nil
        }
    }
}
