import Foundation

/// One of a device's own display panels, by CoreSimulator's name for it.
///
/// Every device has a `primary`. A foldable (iPhone Duo) adds a
/// `primary-1` — the unfolded panel — and which of the two is lit is
/// the hinge's decision, not the name's: see `HingeAngle.litPanel`.
public enum IntegratedPanel: Equatable, Sendable {
    case primary
    case secondary

    /// From the `Device Name:` a Connected Screens record carries, or
    /// `capabilities.plist`'s `deviceName`. Externals (`external-0`,
    /// `wireless0`, `resizable`) and older output without a name are
    /// not panels.
    public static func named(_ deviceName: String) -> IntegratedPanel? {
        switch deviceName {
        case "primary": return .primary
        case "primary-1": return .secondary
        default: return nil
        }
    }
}
