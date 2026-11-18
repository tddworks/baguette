import Foundation
import Mockable

/// Host I/O panel that creates/attaches the CarPlay external display.
/// Domain noun for "External Displays" in the Simulator menu — not a
/// Manager/Service/Port. AppleScript / Accessibility live in Infra.
@Mockable
protocol ExternalDisplays: Sendable {
    /// Idempotent: I/O → External Displays → CarPlay. No-op if already on.
    func enableCarPlay() throws

    /// Detach and reattach, whatever the probe says.
    ///
    /// `enableCarPlay` is guarded by `isCarPlayConnected` so it can't
    /// tear down a display that is already working. That guard is
    /// exactly wrong for the case where the listed display is a stale
    /// registration with no framebuffer: the probe says "connected",
    /// enabling does nothing, and there is still nothing to stream.
    /// This is the caller saying they've seen the listing and it is no
    /// good.
    func reattachCarPlay() throws

    /// True when a CarPlay external display is connected (live probe).
    ///
    /// Names-a-screen, not can-stream-it: a screen registered without a
    /// framebuffer still answers true here. Callers that need a
    /// streamable plane must resolve the display instead.
    var isCarPlayConnected: Bool { get }
}
