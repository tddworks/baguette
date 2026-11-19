import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// The Android family as a source of `Devices`: what adb lists, with adb's
/// child process stood in for.
@Suite("AndroidDevices")
struct AndroidDevicesTests {
    private static let adbPath = URL(fileURLWithPath: "/opt/homebrew/bin/adb")
    private static let listing = Data("""
        List of devices attached
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
        37201FDJH004VE         device usb:1-1 product:panther model:Pixel_7 device:panther transport_id:3

        """.utf8)

    private static let pixel = RunningEmulator(serial: "emulator-5554", avd: "baguette_pixel", port: 8554, token: "tok")

    private func devices(_ fake: FakeDevicectl, running: [RunningEmulator] = [],
                         installed: [String] = []) -> AndroidDevices {
        AndroidDevices(adb: AndroidTool(executable: Self.adbPath, makeSubprocess: fake.make),
                       emulator: URL(fileURLWithPath: "/sdk/emulator/emulator"),
                       runningEmulators: { running }, installedAVDs: { installed })
    }

    @Test func `should list the Android devices adb is attached to`() {
        let fake = FakeDevicectl()
        fake.output = Self.listing

        let all = devices(fake).all

        #expect(all.map(\.id) == ["emulator-5554", "37201FDJH004VE"])
        #expect(all.map(\.name) == ["sdk gphone64 arm64", "Pixel 7"])
        #expect(all.map(\.kind) == [DeviceKind(platform: .android, reality: .emulated, model: "sdk_gphone64_arm64"),
                                    DeviceKind(platform: .android, reality: .physical, model: "Pixel_7")])
        #expect(all.map(\.state) == [.ready, .ready])
        #expect(fake.arguments == [["devices", "-l"]])
    }

    @Test func `should find an Android device by its serial`() throws {
        let fake = FakeDevicectl()
        fake.output = Self.listing

        #expect(try devices(fake).find(id: "37201FDJH004VE")?.name == "Pixel 7")
        #expect(try devices(fake).find(id: "nobody") == nil)
    }

    @Test func `should list no Android devices when adb isn't installed`() {
        #expect(AndroidDevices(adb: nil).all.isEmpty)
    }

    @Test func `should list no Android devices when adb fails`() {
        let fake = FakeDevicectl()
        fake.status = 1

        #expect(devices(fake).all.isEmpty)
    }

    @Test func `should give an emulator with a control API its power, screen and every input role`() {
        let fake = FakeDevicectl()
        fake.output = Self.listing

        let emulator = devices(fake, running: [Self.pixel]).all.first

        #expect(emulator?.abilities.names == ["power", "screen", "touch", "press", "key", "scroll"])
    }

    @Test func `should name a running emulator by its AVD, the same across boots`() throws {
        let fake = FakeDevicectl()
        fake.output = Self.listing

        let all = devices(fake, running: [Self.pixel]).all

        #expect(all.map(\.id) == ["baguette_pixel", "37201FDJH004VE"])
        #expect(try devices(fake, running: [Self.pixel]).find(id: "baguette_pixel")?.state == .ready)
    }

    @Test func `should list an installed emulator that isn't running as off, to be turned on`() {
        let fake = FakeDevicectl()
        fake.output = Self.listing

        let all = devices(fake, running: [Self.pixel], installed: ["baguette_pixel", "Pixel_9"]).all

        #expect(all.map(\.id) == ["baguette_pixel", "37201FDJH004VE", "Pixel_9"])
        let off = all.last
        #expect(off?.state == .off)
        #expect(off?.kind.reality == .emulated)
        #expect(off?.abilities.names == ["power"])
    }

    @Test func `should give an Android device it can't reach yet no abilities`() {
        let fake = FakeDevicectl()
        fake.output = Self.listing

        #expect(devices(fake).all.map { $0.abilities.names } == [[], []])
    }
}
