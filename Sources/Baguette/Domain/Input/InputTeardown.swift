import Foundation

/// What an input session hands back when it ends.
///
/// The pointer service is created per HID client, so the session that
/// created it is the one that returns it.
///
/// The external plane's digitizer is not ours to return. baguette attaches
/// to a CarPlay display the host already brought up, and that display
/// outlives our process — a `baguette input` invocation is one gesture long.
/// Unregistering the digitizer leaves the window on screen and dead to
/// touch, for the host's own pointer as much as for ours. It is also the
/// dangerous direction: `SimHIDVirtualServiceManager` throws on a target
/// nothing registered and takes `backboardd` and SpringBoard with it, where
/// a registered target delivering nowhere is simply ignored. Creating is
/// idempotent — the guest keys its registry by target — so re-warming a
/// plane the host already built a digitizer for costs nothing, which is why
/// only the create half of the pair is ours to send.
struct InputTeardown: Equatable, Sendable {
    let releasesPointer: Bool
    let releasesExternalDigitizer: Bool

    /// Plane-independent by design: no plane releases a digitizer it
    /// shares with the host's own window for that display.
    static func forPlane(_ kind: DisplayKind) -> InputTeardown {
        InputTeardown(releasesPointer: true, releasesExternalDigitizer: false)
    }
}
