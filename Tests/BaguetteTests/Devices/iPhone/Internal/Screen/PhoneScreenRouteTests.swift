import Testing
@testable import Baguette

/// Which way a phone's live screen reaches the Mac: AVConference's receiver,
/// or baguette's own, chosen by BAGUETTE_PHONE_SCREEN.
@Suite("PhoneScreenRoute")
struct PhoneScreenRouteTests {
    @Test func `should receive the phone's screen through AVConference when nothing says otherwise`() {
        #expect(PhoneScreenRoute(environment: [:]) == .avconference)
    }

    @Test func `should receive the phone's screen through baguette's own receiver when BAGUETTE_PHONE_SCREEN says rtp`() {
        #expect(PhoneScreenRoute(environment: ["BAGUETTE_PHONE_SCREEN": "rtp"]) == .rtp)
    }

    @Test func `should keep AVConference when BAGUETTE_PHONE_SCREEN names no route`() {
        #expect(PhoneScreenRoute(environment: ["BAGUETTE_PHONE_SCREEN": "carrier-pigeon"]) == .avconference)
    }
}
