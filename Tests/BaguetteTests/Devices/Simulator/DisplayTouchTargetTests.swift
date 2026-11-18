import Testing
@testable import Baguette
@testable import BaguetteDevice

/// Both planes address a **constant**. A HID target is only valid if
/// some create-service message registered it, so it is never computed —
/// not from a screen id, not from a plist, not from anything.
@Suite("DisplayTouchTarget")
struct DisplayTouchTargetTests {

    /// With no panel bound — every single-panel device, where `input()`
    /// never pays for a guest round-trip — the phone plane addresses the
    /// built-in digitizer slot.
    @Test func `should touch the built-in digitizer slot on a phone when no panel is bound`() {
        let target = DisplayTouchTarget.resolve(
            kind: .phone,
            connectedScreenId: nil,
            derive: { _ in 0xDEAD_BEEF }
        )
        #expect(target == IndigoHIDTouchTarget.phone)
    }

    // MARK: - foldable panels

    /// `SimHIDVirtualServiceManager createDigitizerForTargetID:withDisplayUID:isBuiltIn:`
    /// registers every panel's `ScreenTouchService` under the target the
    /// host's create message carried — which it insists has "the
    /// ScreenID mask bit": `0x40000000 | screenId`. That is the
    /// `1073741825` (`0x40000001`) in the guest's published list, and it
    /// is the cover panel's own digitizer, not an accident.
    ///
    /// A built-in panel is *also* stored into the `@50` (`0x32`) slot —
    /// and `setBuiltInDigitizerService:` overwrites, so on iPhone Duo,
    /// where the cover (screen 1) and unfolded (screen 3) digitizers are
    /// both created built-in, `0x32` ends up on the second: the dark
    /// panel. backboardd confirms it — a tap sent to `0x32` arrives on
    /// `ACEFADE00000009`, the sender for screen 3's display UUID.
    @Test func `should address a panel's own digitizer as its screen id under the mask bit`() {
        #expect(IndigoHIDTouchTarget.panel(screenId: 1) == 0x4000_0001)
        #expect(IndigoHIDTouchTarget.panel(screenId: 3) == 0x4000_0003)
        #expect(IndigoHIDTouchTarget.panel(screenId: 1) == 1_073_741_825)
    }

    /// So on a foldable the phone plane addresses the bound panel's own
    /// registration rather than the shared slot.
    @Test func `should touch the bound panel's own digitizer on a foldable phone`() {
        #expect(
            DisplayTouchTarget.resolve(
                kind: .phone, connectedScreenId: 1, derive: { _ in nil }
            ) == 0x4000_0001
        )
        #expect(
            DisplayTouchTarget.resolve(
                kind: .phone, connectedScreenId: 3, derive: { _ in nil }
            ) == 0x4000_0003
        )
    }

    /// The panel target is a registration, not a computation over any
    /// screen: only Integrated screens get a create-digitizer message.
    /// `0x40000002` — TVOut — is the one that took the guest down.
    @Test func `should list the cover panel's own digitizer among the probe targets`() {
        #expect(IndigoHIDTouchTarget.knownProbeTargets.contains(IndigoHIDTouchTarget.panel(screenId: 1)))
        #expect(!IndigoHIDTouchTarget.knownProbeTargets.contains(0x4000_0002))
    }

    /// The external plane addresses the CarPlay **service**, which
    /// registers at one fixed target — not at anything derived from the
    /// screen it happens to be showing on.
    ///
    /// Deriving it from the connected screen id is what restarted the
    /// guest, and `SimHIDVirtualServiceManager` says so in as many
    /// words when the event arrives:
    ///
    ///     *** Terminating app due to uncaught exception
    ///     'NSInternalInconsistencyException', reason: 'Encountered HID
    ///     event with unexpected target 1073741826 not in known targets:
    ///     ( 50, 13, 11, 53, 51, 302, 300, 1, 14, 60, 12, 100, 54,
    ///       1073741825, 301 )'
    ///
    /// `1073741826` is `0x40000002` — screen id 2, dutifully derived
    /// by `IndigoHIDTargetForScreen`, and registered by nothing.
    ///
    /// The real target is the `1` sitting quietly in that list. The
    /// guest keys its registry on the raw targetID the create message
    /// carries at `[0x40]`, which the host hardcodes to `1`:
    ///
    ///     allServices[ numberWithUnsignedInt:(targetID) ] = service
    ///
    /// Alongside it sit `50` (`0x32`, phone), `53` (`0x35`, pointer) and
    /// `54` (`0x36`, mouse) — every entry is a service something
    /// explicitly created, and every one is a constant, never a
    /// computation.
    @Test func `should touch the CarPlay service target whatever screen CarPlay is on`() {
        for screenId in [UInt32(2), 3, 204] {
            #expect(
                DisplayTouchTarget.resolve(
                    kind: .carPlay,
                    connectedScreenId: screenId,
                    derive: { $0 | 0x4000_0000 }
                ) == IndigoHIDTouchTarget.carPlay
            )
        }
        #expect(IndigoHIDTouchTarget.carPlay == 1)
        #expect(IndigoHIDTouchTarget.carPlay != IndigoHIDTouchTarget.phone)
    }

    /// The screen id is no longer an input to the answer, so the
    /// derivation is not consulted at all.
    @Test func `should never derive the CarPlay target from the screen`() {
        var derived = false
        _ = DisplayTouchTarget.resolve(
            kind: .carPlay,
            connectedScreenId: 3,
            derive: { _ in derived = true; return 0x4000_0003 }
        )
        #expect(!derived)
    }

    // MARK: - probe override

    /// Finding the right CarPlay target is a search, and the guest only
    /// publishes the registered set when it rejects one. An env
    /// override makes a candidate a restart rather than a rebuild.
    @Test func `should touch the overridden target on CarPlay when an override is set`() {
        #expect(
            DisplayTouchTarget.resolve(
                kind: .carPlay, connectedScreenId: 2,
                derive: { _ in nil }, override: 302
            ) == 302
        )
    }

    /// The phone's digitizer is not part of the search.
    @Test func `should leave the phone's digitizer alone when an override is set`() {
        #expect(
            DisplayTouchTarget.resolve(
                kind: .phone, connectedScreenId: nil,
                derive: { _ in nil }, override: 302
            ) == IndigoHIDTouchTarget.phone
        )
        #expect(
            DisplayTouchTarget.resolve(
                kind: .phone, connectedScreenId: 1,
                derive: { _ in nil }, override: 302
            ) == IndigoHIDTouchTarget.panel(screenId: 1)
        )
    }

    @Test func `should read a target override written in decimal or hex`() {
        #expect(DisplayTouchTarget.parseOverride("302") == 302)
        #expect(DisplayTouchTarget.parseOverride("0x12e") == 302)
        #expect(DisplayTouchTarget.parseOverride("0X40000001") == 0x4000_0001)
        #expect(DisplayTouchTarget.parseOverride("  302  ") == 302)
    }

    /// A typo must not become a number. Every unregistered target is one
    /// that kills the guest, so "unparseable" has to mean "use the
    /// known-good constant", never "use zero".
    @Test func `should ignore a target override that is not a number`() {
        for raw in ["", "   ", "abc", "0x", "3 0 2", "-1", "0xZZ"] {
            #expect(DisplayTouchTarget.parseOverride(raw) == nil, "\(raw)")
        }
        #expect(DisplayTouchTarget.parseOverride(nil) == nil)
    }

    /// The override is a *probe*, and the set it probes is the one the
    /// guest published when it threw. A number outside that set is
    /// precisely the unregistered target this whole type exists to keep
    /// out, so a typo in an env var must not be the thing that takes
    /// `backboardd` down.
    @Test func `should refuse a target override outside the registered set`() {
        for raw in ["0x40000002", "1073741826", "2", "999", "0x0"] {
            #expect(DisplayTouchTarget.parseOverride(raw) == nil, "\(raw)")
        }
    }

    /// And a refused override leaves the plane on the constant it would
    /// have used anyway, rather than on nothing.
    @Test func `should keep CarPlay on its own service when the override is unregistered`() {
        #expect(
            DisplayTouchTarget.resolve(
                kind: .carPlay, connectedScreenId: 2,
                derive: { _ in nil },
                override: DisplayTouchTarget.parseOverride("0x40000002")
            ) == IndigoHIDTouchTarget.carPlay
        )
    }

    /// Everything the guest named as registered, so a sweep can be
    /// driven from the list rather than from memory.
    @Test func `should list only registered targets among the probe targets`() {
        #expect(IndigoHIDTouchTarget.knownProbeTargets.contains(IndigoHIDTouchTarget.phone))
        #expect(IndigoHIDTouchTarget.knownProbeTargets.contains(IndigoHIDTouchTarget.carPlay))
        #expect(!IndigoHIDTouchTarget.knownProbeTargets.contains(0x4000_0002))
    }

    /// Screen ids start at 1; a `0` is what the enumerate parser yields
    /// for a record with none, and `0x40000000` on its own is registered
    /// by nothing. Either way there is no panel to address.
    @Test func `should touch the built-in digitizer slot on a phone when the screen id is absent or zero`() {
        for absent in [UInt32?.none, 0] {
            let target = DisplayTouchTarget.resolve(
                kind: .phone,
                connectedScreenId: absent,
                derive: { _ in nil }
            )
            #expect(target == IndigoHIDTouchTarget.phone)
        }
    }
}
