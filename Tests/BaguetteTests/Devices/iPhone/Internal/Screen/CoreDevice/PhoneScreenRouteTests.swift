import Testing
@testable import Baguette

/// Which way a phone's live screen reaches the Mac: baguette's own RTP
/// receiver, or AVConference's, chosen by BAGUETTE_PHONE_SCREEN.
@Suite("PhoneScreenRoute")
struct PhoneScreenRouteTests {
    @Test func `should receive the phone's screen through baguette's own receiver when nothing says otherwise`() {
        #expect(PhoneScreenRoute(environment: [:]) == .rtp)
    }

    @Test func `should receive the phone's screen through AVConference when BAGUETTE_PHONE_SCREEN says so`() {
        #expect(PhoneScreenRoute(environment: ["BAGUETTE_PHONE_SCREEN": "avconference"]) == .avconference)
    }

    @Test func `should keep baguette's own receiver when BAGUETTE_PHONE_SCREEN names no route`() {
        #expect(PhoneScreenRoute(environment: ["BAGUETTE_PHONE_SCREEN": "carrier-pigeon"]) == .rtp)
    }

    @Test func `should give baguette's own receiver for the rtp route`() throws {
        #expect(try PhoneScreenRoute.rtp.receiver() is RTPReceiver)
    }
}
