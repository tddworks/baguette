import Testing
@testable import Baguette
@testable import BaguetteDevice

/// Ending a session must not unregister the digitizer behind an external
/// plane. baguette does not own that display — the host's own window for it
/// was already there and outlives our process — so removing the service
/// leaves that window on screen and dead to touch. It is also the dangerous
/// direction: `SimHIDVirtualServiceManager` throws on a target nothing
/// registered and takes `backboardd` with it, where a registered target
/// delivering nowhere is harmless.
@Suite("InputTeardown")
struct InputTeardownTests {

    @Test func `should leave the external digitizer registered when a CarPlay session ends`() {
        #expect(InputTeardown.forPlane(.carPlay).releasesExternalDigitizer == false)
    }

    @Test func `should have no external digitizer to release when a phone session ends`() {
        #expect(InputTeardown.forPlane(.phone).releasesExternalDigitizer == false)
    }

    @Test func `should release the pointer service it created when any session ends`() {
        #expect(InputTeardown.forPlane(.phone).releasesPointer)
        #expect(InputTeardown.forPlane(.carPlay).releasesPointer)
    }
}
