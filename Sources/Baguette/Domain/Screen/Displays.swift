import Foundation
import Mockable

/// Plural aggregate hung off Simulator — indexes the simulator's
/// display planes (phone + CarPlay). Does not enable CarPlay itself;
/// that lives on `ExternalDisplays`.
@Mockable
protocol Displays: Sendable {
    var phone: any Display { get }
    var carPlay: any Display { get }

    /// The phone plane pinned to one of the device's own panels, the
    /// hinge not consulted. A foldable's page brings the other panel in
    /// while the hinge is still turning — the runtime lights the target
    /// panel as the sweep starts — so the stream it opens has to name
    /// its panel rather than follow the angle. On a single-panel device
    /// any pin is the one panel there is.
    func panel(_ panel: IntegratedPanel) -> any Display
}

extension Displays {
    subscript(_ kind: DisplayKind) -> any Display {
        switch kind {
        case .phone: return phone
        case .carPlay: return carPlay
        }
    }
}
