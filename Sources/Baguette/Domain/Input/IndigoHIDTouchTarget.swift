import BaguetteDevice
import Foundation

/// Indigo HID digitizer routing targets.
///
/// Every one of these addresses a **virtual service** the guest has been
/// told to create. `SimHIDVirtualServiceManager` keeps them in a
/// dictionary and throws — killing `backboardd`, and SpringBoard with
/// it — when an event arrives for a target it has never heard of:
///
///     *** Terminating app due to uncaught exception
///     'NSInternalInconsistencyException', reason: 'Encountered HID
///     event with unexpected target 1073741826 not in known targets:
///     ( 50, 13, 11, 53, 51, 302, 300, 1, 14, 60, 12, 100, 54,
///       1073741825, 301 )'
///
/// So a target is only ever a constant that some create-service message
/// registered. It is never computed from a screen, a display id, or a
/// plist.
enum IndigoHIDTouchTarget {
    /// The built-in digitizer slot (`0x32` — `50` in the list above).
    ///
    /// Not a digitizer of its own: `createDigitizerForTargetID:withDisplayUID:isBuiltIn:`
    /// stores every *built-in* panel's service into this slot as well
    /// as under its own target, and `setBuiltInDigitizerService:`
    /// overwrites. One panel, one owner. A foldable creates two
    /// built-in panels — iPhone Duo's cover (screen 1) then unfolded
    /// (screen 3) — and the slot ends on the second, which is the dark
    /// one while folded. For those, address the panel: `panel(screenId:)`.
    static let phone: UInt32 = 0x32

    /// One integrated panel's own digitizer registration.
    ///
    /// The host's create-digitizer message carries `0x40000000 | screenId`
    /// as its target — SimulatorHID refuses anything without "the
    /// ScreenID mask bit" — and the guest keys the service on that raw
    /// value. `1073741825` in the list above is screen 1's; it was read
    /// as a near-miss when CarPlay was being found, and it is in fact
    /// the cover panel's own digitizer.
    ///
    /// Still a registration, not a computation: only Integrated screens
    /// get a create-digitizer message. Screen 2 is TVOut, so
    /// `0x40000002` is the number that took the guest down. Pass only a
    /// screen id that Connected Screens lists as Integrated.
    static func panel(screenId: UInt32) -> UInt32 {
        0x4000_0000 | screenId
    }

    /// Every target the guest listed as known, for probing. Registered
    /// means safe to send to: a wrong one goes to the wrong surface,
    /// only an *unregistered* one throws and takes the guest down. So
    /// this is also the set `DisplayTouchTarget.parseOverride` accepts —
    /// an env var is not somewhere you want to be able to name a target
    /// from outside it.
    ///
    /// `50`/`53`/`54` are already accounted for (phone / pointer /
    /// mouse) and `1` is CarPlay's own service. `1073741825`
    /// (`0x40000001`) is registered by something else entirely and
    /// routes to the integrated digitizer — which is why sending
    /// CarPlay's touches there landed them on the phone. The `300`–`302`
    /// run is the interesting unexplored group.
    static let knownProbeTargets: [UInt32] = [
        1, 11, 12, 13, 14, 50, 51, 53, 54, 60, 100, 300, 301, 302, 0x4000_0001,
    ]

    /// The CarPlay service — plain `1`, and fixed, not per-screen.
    ///
    /// The guest side settles it. `SimulatorHID` exposes
    /// `-[SimHIDVirtualServiceManager createCarplayServiceForTargetID:hasDigitizer:]`,
    /// its dispatcher reads both arguments straight out of the message
    ///
    ///     ldr  w2, [x25, #0x40]   ; targetID     ← host hardcodes 1
    ///     ldrb w8, [x25, #0x44]   ; hasDigitizer ← hasTouchScreen
    ///
    /// and the registration is keyed on the raw value, unshifted and
    /// unflagged:
    ///
    ///     allServices[ numberWithUnsignedInt:(targetID) ] = service
    ///
    /// So `IndigoHIDMessageToCreateCarPlayService` writing `1` into
    /// `[0x40]` means the service registers under `1`, exactly as its
    /// pointer and mouse siblings register under the `0x35` / `0x36`
    /// they write into the same slot.
    ///
    /// Two wrong answers were tried first, and both are instructive.
    /// `0x40000002` came from `IndigoHIDTargetForScreen(screenId)` — a
    /// real SimulatorKit export that returns `0x40000000 | screenId`,
    /// which nothing registers, so the guest threw and died.
    /// `0x40000001` was `1` with a `0x40000000` flag invented to match
    /// it; that one *is* registered, by something else, so it did not
    /// crash — it quietly delivered CarPlay's touches to the phone.
    static let carPlay: UInt32 = 1
}
