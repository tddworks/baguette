import Testing

@testable import Baguette
@testable import BaguetteDevice

@Suite("DisplayKind digitizer")
struct DisplayKindDigitizerTests {

    /// The phone's digitizer is part of the device and always there;
    /// asking the guest to build one would be asking for a second.
    @Test func `should need no digitizer built for the phone screen`() {
        #expect(!DisplayKind.phone.needsExternalDigitizer)
    }

    @Test func `should need a digitizer built for an external screen`() {
        #expect(DisplayKind.carPlay.needsExternalDigitizer)
    }
}
