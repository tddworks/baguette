import Testing
@testable import Baguette

/// Ending a session must not unregister the digitizer behind an external
/// plane. baguette does not own that display — the host's own window for it
/// was already there and outlives our process — so removing the service
/// leaves that window on screen and dead to touch. It is also the dangerous
/// direction: `SimHIDVirtualServiceManager` throws on a target nothing
/// registered and takes `backboardd` with it, where a registered target
/// delivering nowhere is harmless.
@Suite("InputTeardown")
struct InputTeardownTests {

    @Test func `a carPlay session leaves the external digitizer registered`() {
        #expect(InputTeardown.forPlane(.carPlay).releasesExternalDigitizer == false)
    }

    @Test func `a phone session has no external digitizer to release`() {
        #expect(InputTeardown.forPlane(.phone).releasesExternalDigitizer == false)
    }

    @Test func `every plane returns the pointer service it created`() {
        #expect(InputTeardown.forPlane(.phone).releasesPointer)
        #expect(InputTeardown.forPlane(.carPlay).releasesPointer)
    }
}
