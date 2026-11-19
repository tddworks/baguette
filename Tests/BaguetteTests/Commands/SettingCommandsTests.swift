import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `baguette clipboard`, `status-bar` and `interface` against the devices a
/// test hands them.
@Suite("Setting commands")
struct SettingCommandsTests {

    private struct Refused: Error, CustomStringConvertible {
        var description: String { "refused" }
    }

    // MARK: - clipboard

    private func pasteboard(text: String = "", failing: Bool = false) -> any Devices {
        let pasteboard = MockPasteboard()
        if failing {
            given(pasteboard).text().willThrow(Refused())
            given(pasteboard).syncFromHost().willThrow(Refused())
            given(pasteboard).syncToHost().willThrow(Refused())
        } else {
            given(pasteboard).text().willReturn(text)
            given(pasteboard).syncFromHost().willReturn()
            given(pasteboard).syncToHost().willReturn()
        }
        return routeDevices { $0.register(.pasteboard) { pasteboard } }
    }

    @Test func `should answer the pasteboard's text byte for byte, with no newline added`() async throws {
        let ran = try await run(try ClipboardCommand.Get.parse(["--udid", "U"]), on: pasteboard(text: "héllo"))

        #expect(ran.written == Data("héllo".utf8))
    }

    @Test func `should exit 1 when the pasteboard can't be read`() async throws {
        let ran = try await run(try ClipboardCommand.Get.parse(["--udid", "U"]), on: pasteboard(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["clipboard get failed: refused"])
    }

    @Test func `should sync the host pasteboard onto the device`() async throws {
        let ran = try await run(try ClipboardCommand.Sync.parse(["--udid", "U"]), on: pasteboard())

        #expect(ran.told == ["Synced host pasteboard onto iPhone 17"])
    }

    @Test func `should exit 1 when syncing onto the device fails`() async throws {
        let ran = try await run(try ClipboardCommand.Sync.parse(["--udid", "U"]), on: pasteboard(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["clipboard sync failed: refused"])
    }

    @Test func `should copy the device pasteboard onto the host`() async throws {
        let ran = try await run(try ClipboardCommand.Copy.parse(["--udid", "U"]), on: pasteboard())

        #expect(ran.told == ["Copied iPhone 17 pasteboard onto the host"])
    }

    @Test func `should exit 1 when copying onto the host fails`() async throws {
        let ran = try await run(try ClipboardCommand.Copy.parse(["--udid", "U"]), on: pasteboard(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["clipboard copy failed: refused"])
    }

    @Test func `should exit 1 reading the clipboard of a device without one`() async throws {
        let ran = try await run(try ClipboardCommand.Get.parse(["--udid", "U"]), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do pasteboard"])
    }

    // MARK: - status-bar

    private func statusBar(failing: Bool = false) -> any Devices {
        let bar = MockStatusBar()
        if failing {
            given(bar).override(.any).willThrow(Refused())
            given(bar).clear().willThrow(Refused())
        } else {
            given(bar).override(.any).willReturn()
            given(bar).clear().willReturn()
        }
        return routeDevices { $0.register(.statusBar) { bar } }
    }

    @Test func `should override the status bar and say so`() async throws {
        let ran = try await run(try StatusBarCommand.Override.parse(["--udid", "U", "--time", "9:41"]),
                                on: statusBar())

        #expect(ran.exit == 0)
        #expect(ran.told == ["Set iPhone 17 status bar"])
    }

    @Test func `should exit 1 when no status-bar field is given`() async throws {
        let ran = try await run(try StatusBarCommand.Override.parse(["--udid", "U"]), on: statusBar())

        #expect(ran.exit == 1)
        #expect(ran.told == ["status-bar override: set at least one field"])
    }

    @Test func `should exit 1 when the override fails`() async throws {
        let ran = try await run(try StatusBarCommand.Override.parse(["--udid", "U", "--battery-level", "50"]),
                                on: statusBar(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["status-bar override failed: refused"])
    }

    @Test func `should clear the status bar overrides and say so`() async throws {
        let ran = try await run(try StatusBarCommand.Clear.parse(["--udid", "U"]), on: statusBar())

        #expect(ran.told == ["Cleared iPhone 17 status bar overrides"])
    }

    @Test func `should exit 1 when clearing the status bar fails`() async throws {
        let ran = try await run(try StatusBarCommand.Clear.parse(["--udid", "U"]), on: statusBar(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["status-bar clear failed: refused"])
    }

    @Test func `should exit 1 overriding the status bar of a device without one`() async throws {
        let ran = try await run(try StatusBarCommand.Clear.parse(["--udid", "U"]), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do statusBar"])
    }

    // MARK: - interface

    private func interface(failing: Bool = false) -> any Devices {
        let interface = MockInterface()
        given(interface).appearance().willReturn(.dark)
        given(interface).increaseContrast().willReturn(.enabled)
        given(interface).contentSize().willReturn(.large)
        if failing {
            given(interface).setAppearance(.any).willThrow(Refused())
            given(interface).setIncreaseContrast(.any).willThrow(Refused())
            given(interface).setContentSize(.any).willThrow(Refused())
        } else {
            given(interface).setAppearance(.any).willReturn()
            given(interface).setIncreaseContrast(.any).willReturn()
            given(interface).setContentSize(.any).willReturn()
        }
        return routeDevices { $0.register(.interface) { interface } }
    }

    @Test func `should answer the current appearance when none is given`() async throws {
        let ran = try await run(try InterfaceCommand.Appearance.parse(["--udid", "U"]), on: interface())

        #expect(ran.said == ["dark"])
    }

    @Test func `should set the appearance given`() async throws {
        let ran = try await run(try InterfaceCommand.Appearance.parse(["--udid", "U", "light"]), on: interface())

        #expect(ran.exit == 0)
        #expect(ran.said.isEmpty)
    }

    @Test func `should answer the current contrast when none is given`() async throws {
        let ran = try await run(try InterfaceCommand.Contrast.parse(["--udid", "U"]), on: interface())

        #expect(ran.said == ["enabled"])
    }

    @Test func `should set the contrast given`() async throws {
        let ran = try await run(try InterfaceCommand.Contrast.parse(["--udid", "U", "disabled"]), on: interface())

        #expect(ran.exit == 0)
    }

    @Test func `should answer the current text size when none is given`() async throws {
        let ran = try await run(try InterfaceCommand.TextSize.parse(["--udid", "U"]), on: interface())

        #expect(ran.said == ["large"])
    }

    @Test func `should exit 1 when the text size can't be set`() async throws {
        let ran = try await run(try InterfaceCommand.TextSize.parse(["--udid", "U", "increment"]),
                                on: interface(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["interface update failed: refused"])
    }

    @Test func `should exit 1 reading the interface of a device without one`() async throws {
        let ran = try await run(try InterfaceCommand.Appearance.parse(["--udid", "U"]), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do interface"])
    }
}
