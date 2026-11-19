import Testing
@testable import Baguette
@testable import BaguetteDevice

/// Xcode 27's Device Hub attaches a guest HID daemon (`dtuhidd`) to every
/// booted simulator. It announces itself through one Darwin notify state
/// in the guest, and that state is the whole signal baguette reads to
/// decide whether the legacy Indigo input surface has been shadowed.
@Suite("DeviceHubAttachment")
struct DeviceHubAttachmentTests {

    @Test func `should watch the notify state Device Hub's HID daemon publishes`() {
        #expect(DeviceHubAttachment.stateKey == "com.apple.coredevice.dtuhidd.active")
    }

    @Test func `should see Device Hub attached when its state is active`() {
        let attachment = DeviceHubAttachment.parsing("com.apple.coredevice.dtuhidd.active 1\n")
        #expect(attachment.attached)
    }

    @Test func `should see the surface unshadowed when the state is zero`() {
        let attachment = DeviceHubAttachment.parsing("com.apple.coredevice.dtuhidd.active 0\n")
        #expect(!attachment.attached)
    }

    @Test func `should see no Device Hub when the device has no readable state`() {
        // Xcode 26 runtimes never publish the key; `notifyutil -g` on a
        // key nothing set prints 0, and a failed spawn prints nothing.
        #expect(!DeviceHubAttachment.parsing(nil).attached)
        #expect(!DeviceHubAttachment.parsing("").attached)
        #expect(!DeviceHubAttachment.parsing("garbage").attached)
    }

    @Test func `should ignore any notify key other than Device Hub's`() {
        #expect(!DeviceHubAttachment.parsing("com.apple.something.else 1\n").attached)
    }

    @Test func `should advise baguette heal when Device Hub has attached`() {
        let advisory = DeviceHubAttachment(attached: true).advisory(udid: "ABC")
        #expect(advisory?.contains("baguette heal --udid ABC") == true)
        #expect(advisory?.contains("Device Hub") == true)
    }

    @Test func `should give no advice when the surface is unshadowed`() {
        #expect(DeviceHubAttachment(attached: false).advisory(udid: "ABC") == nil)
    }
}
