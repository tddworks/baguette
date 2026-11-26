import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// iPhone Duo takes its hardware buttons and keyboard keys only from a HID
/// buttons service: `HIDButtons` presses each in the guest as Device Hub's
/// buttons do.
@Suite("HIDButtonsKeys")
struct HIDButtonsKeysTests {
    private func make() -> (HIDButtonsKeys, SimctlSpawnSessionTests.Guest) {
        let (session, guest) = SimctlSpawnSessionTests.make(program: "HIDButtons", path: "/tmp/builds/abc/HIDButtons")
        return (HIDButtonsKeys(session: session), guest)
    }

    @Test func `should press a hardware key as Device Hub presses it, for as long as asked`() throws {
        let (keys, guest) = make()
        try keys.press(HIDUsage(page: 12, usage: 233), holding: [], hold: 0.25)
        try keys.press(HIDUsage(page: 0xFF00, usage: 0x66), holding: [], hold: 1.5)
        #expect(guest.runs.first?.contains("/tmp/builds/abc/HIDButtons") == true)
        #expect(guest.written == ["button 12 233 250\n", "button 65280 102 1500\n"])
    }

    @Test func `should press a keyboard key with its modifiers held`() throws {
        let (keys, guest) = make()
        try keys.press(
            HIDUsage(page: 7, usage: 4),
            holding: [HIDUsage(page: 7, usage: 0xE1), HIDUsage(page: 7, usage: 0xE3)], hold: 0.1)
        try keys.press(HIDUsage(page: 7, usage: 5), holding: [], hold: 0.1)
        #expect(guest.written == ["button 7 4 100 7 225 7 227\n", "button 7 5 100\n"])
    }

    // A key that fails is a key's failure, not the hinge's.
    @Test func `should fail as HIDButtons, not as the hinge`() {
        let (keys, guest) = make()
        guest.answer = { _ in ["done 1\n"] }
        #expect(throws: InjectedProgramError.failed(program: "HIDButtons", status: 1)) {
            try keys.press(HIDUsage(page: 7, usage: 4), holding: [], hold: 0.1)
        }
    }
}
