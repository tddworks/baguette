import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// What `adb devices -l` prints, read as the Android devices it lists.
@Suite("AdbListing")
struct AdbListingTests {
    private static func listing(_ lines: String...) -> String {
        (["List of devices attached"] + lines + [""]).joined(separator: "\n")
    }

    @Test func `should list an emulator adb is attached to as an emulated Android device`() {
        let entries = AdbListing.entries(in: Self.listing(
            "emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1"))

        #expect(entries == [AdbListing.Entry(serial: "emulator-5554", name: "sdk gphone64 arm64",
                                             reality: .emulated, state: .ready, model: "sdk_gphone64_arm64")])
    }

    @Test func `should list a phone on a cable as a physical Android device, named by its model`() {
        let entries = AdbListing.entries(in: Self.listing(
            "37201FDJH004VE         device usb:1-1 product:panther model:Pixel_7 device:panther transport_id:3"))

        #expect(entries == [AdbListing.Entry(serial: "37201FDJH004VE", name: "Pixel 7",
                                             reality: .physical, state: .ready, model: "Pixel_7")])
    }

    @Test func `should list a phone over Wi-Fi by its network serial`() {
        let entries = AdbListing.entries(in: Self.listing(
            "192.168.1.23:5555      device product:panther model:Pixel_7 device:panther transport_id:4"))

        #expect(entries.map(\.serial) == ["192.168.1.23:5555"])
        #expect(entries.map(\.reality) == [.physical])
    }

    @Test func `should list a phone waiting on its USB debugging prompt as unavailable, saying so`() {
        let entries = AdbListing.entries(in: Self.listing("R5CT12345AB            unauthorized usb:1-1 transport_id:2"))

        #expect(entries.map(\.state) == [.unavailable(reason: "accept the USB debugging prompt on the device")])
        #expect(entries.map(\.name) == ["R5CT12345AB"])
    }

    @Test func `should list a device adb has lost touch with as unavailable`() {
        let entries = AdbListing.entries(in: Self.listing("emulator-5556          offline transport_id:5"))

        #expect(entries.map(\.state) == [.unavailable(reason: "offline")])
    }

    @Test func `should list nothing when adb lists nothing`() {
        #expect(AdbListing.entries(in: Self.listing()).isEmpty)
        #expect(AdbListing.entries(in: "").isEmpty)
    }
}
