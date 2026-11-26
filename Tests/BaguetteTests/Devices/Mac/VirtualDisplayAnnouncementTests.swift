import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies

/// What a `baguette virtual-display` process says once: the display it made,
/// or why it made none.
@Suite("VirtualDisplayAnnouncement")
struct VirtualDisplayAnnouncementTests {
    @Test func `should read the display a process made, by its id and UUID`() {
        #expect(VirtualDisplayAnnouncement(line: "ready 28 454C96D0-B7E4-4AE5-867F-CEB55D7F7992")
            == .ready(id: 28, uuid: "454C96D0-B7E4-4AE5-867F-CEB55D7F7992"))
    }

    @Test func `should read why a process made no display`() {
        #expect(VirtualDisplayAnnouncement(line: "failed the 2x mode never came") == .failed("the 2x mode never came"))
    }

    @Test func `should read nothing from any other line`() {
        #expect(VirtualDisplayAnnouncement(line: "[baguette] log noise") == nil)
        #expect(VirtualDisplayAnnouncement(line: "ready nope UUID") == nil)
        #expect(VirtualDisplayAnnouncement(line: "ready 28") == nil)
    }

    @Test func `should say a made display as a line the parent reads back`() {
        let ready = VirtualDisplayAnnouncement.ready(id: 28, uuid: "U")
        #expect(VirtualDisplayAnnouncement(line: ready.line) == ready)
    }
}
