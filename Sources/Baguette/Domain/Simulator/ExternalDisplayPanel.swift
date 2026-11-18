import BaguetteDevice
import Foundation
import Mockable

/// Host Simulator menu path for I/O → External Displays → CarPlay.
/// Irreducible AppleScript / Accessibility lives in the Infra impl;
/// orchestrators depend on this role noun.
@Mockable
protocol ExternalDisplayPanel: Sendable {
    func enableCarPlay() throws

    /// Disabled → CarPlay, unconditionally. The cycle that clears a
    /// display left registered without a framebuffer behind it, where
    /// enabling alone is a no-op because the host already lists one.
    func recoverCarPlay() throws
}
