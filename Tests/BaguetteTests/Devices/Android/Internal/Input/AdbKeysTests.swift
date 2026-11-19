import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// An Android device's buttons and keyboard through `adb shell input` —
/// with adb's child process stood in for.
@Suite("AdbKeys")
struct AdbKeysTests {
    private func keys(_ fake: FakeDevicectl) -> AdbKeys {
        AdbKeys(serial: "emulator-5554",
                adb: AndroidTool(executable: URL(fileURLWithPath: "/opt/homebrew/bin/adb"), makeSubprocess: fake.make))
    }

    @Test func `should press a button as its key event`() {
        let fake = FakeDevicectl()

        #expect(keys(fake).button(.navigation(.back), duration: 0))

        #expect(fake.arguments == [["-s", "emulator-5554", "shell", "input", "keyevent", "4"]])
    }

    @Test func `should hold a button as a long press`() {
        let fake = FakeDevicectl()

        #expect(keys(fake).button(.hardware(.power), duration: 1))

        #expect(fake.arguments == [["-s", "emulator-5554", "shell", "input", "keyevent", "--longpress", "26"]])
    }

    @Test func `should offer the buttons Android has`() {
        #expect(keys(FakeDevicectl()).available == [.navigation(.home), .navigation(.back), .navigation(.appSwitcher),
                                                    .hardware(.power), .hardware(.lock),
                                                    .hardware(.volumeUp), .hardware(.volumeDown)])
    }

    @Test func `should type a key as its key event`() {
        let fake = FakeDevicectl()

        #expect(keys(fake).key(KeyboardKey(hidUsage: HIDUsage(page: 7, usage: 0x04)), modifiers: [], duration: 0))

        #expect(fake.arguments == [["-s", "emulator-5554", "shell", "input", "keyevent", "29"]])
    }

    @Test func `should type a key with its modifiers as one key combination`() {
        let fake = FakeDevicectl()

        #expect(keys(fake).key(KeyboardKey(hidUsage: HIDUsage(page: 7, usage: 0x04)), modifiers: [.shift], duration: 0))

        #expect(fake.arguments == [["-s", "emulator-5554", "shell", "input", "keycombination", "59", "29"]])
    }

    @Test func `should type text in one input command, its spaces as %s`() {
        let fake = FakeDevicectl()

        #expect(keys(fake).type("hi there"))

        #expect(fake.arguments == [["-s", "emulator-5554", "shell", "input", "text", "hi%sthere"]])
    }

    @Test func `should keep the device's shell from reading what is typed`() {
        let fake = FakeDevicectl()

        _ = keys(fake).type("a&b'c")

        #expect(fake.arguments == [["-s", "emulator-5554", "shell", "input", "text", #"a\&b\'c"#]])
    }

    @Test func `should refuse a key Android has no code for`() {
        let fake = FakeDevicectl()

        #expect(!keys(fake).key(KeyboardKey(hidUsage: HIDUsage(page: 7, usage: 0xFF)), modifiers: [], duration: 0))
        #expect(fake.arguments.isEmpty)
    }

    @Test func `should report a key adb couldn't send`() {
        let fake = FakeDevicectl()
        fake.status = 1

        #expect(!keys(fake).button(.navigation(.home), duration: 0))
    }
}
