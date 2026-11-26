import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies

/// An emulator turned on and off: its AVD started headless, its console told
/// to stop — with adb's and the emulator's processes stood in for.
@Suite("EmulatorPower")
struct EmulatorPowerTests {
    private static let emulatorTool = URL(fileURLWithPath: "/sdk/emulator/emulator")

    private final class Launches: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [[String]] = []
        var all: [[String]] { lock.withLock { _all } }
        func add(_ argv: [String]) { lock.withLock { _all.append(argv) } }
    }

    private func power(serial: String?, _ fake: FakeDevicectl, _ launches: Launches) -> EmulatorPower {
        EmulatorPower(avd: "baguette_pixel", serial: serial, emulator: Self.emulatorTool,
                      adb: AndroidTool(executable: URL(fileURLWithPath: "/opt/homebrew/bin/adb"), makeSubprocess: fake.make),
                      launch: { tool, arguments in launches.add([tool.path] + arguments) })
    }

    @Test func `should turn an emulator on by starting its AVD with no window`() throws {
        let launches = Launches()

        try power(serial: nil, FakeDevicectl(), launches).turnOn()

        #expect(launches.all == [["/sdk/emulator/emulator", "-avd", "baguette_pixel", "-no-window", "-no-audio"]])
    }

    @Test func `should turn a running emulator off through its console`() throws {
        let fake = FakeDevicectl()

        try power(serial: "emulator-5554", fake, Launches()).turnOff()

        #expect(fake.arguments == [["-s", "emulator-5554", "emu", "kill"]])
    }

    @Test func `should leave an emulator that isn't running as it is when turned off`() throws {
        let fake = FakeDevicectl()

        try power(serial: nil, fake, Launches()).turnOff()

        #expect(fake.arguments.isEmpty)
    }
}
