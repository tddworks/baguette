import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `baguette launch`, `fill`, `paste` and `describe-ui` against the devices
/// a test hands them.
@Suite("Screen commands")
struct ScreenCommandsTests {

    private struct Refused: Error, CustomStringConvertible {
        var description: String { "refused" }
    }

    private static let button = AXNode(
        role: "AXButton", label: "Sign In",
        frame: Rect(origin: Point(x: 10, y: 10), size: Size(width: 100, height: 44)))
    private static let tree = AXNode(
        role: "AXApplication", frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 390, height: 844)),
        children: [button])

    private func accessibility(tree: AXNode? = Self.tree) -> MockAccessibility {
        let accessibility = MockAccessibility()
        given(accessibility).describeAll().willReturn(tree)
        given(accessibility).glance().willReturn(tree)
        given(accessibility).wake().willReturn()
        return accessibility
    }

    // MARK: - launch

    private func launching(failing: Bool = false) -> any Devices {
        let apps = MockApps()
        given(apps).terminate(bundleID: .any).willReturn()
        if failing {
            given(apps).launch(bundleID: .any).willThrow(Refused())
        } else {
            given(apps).launch(bundleID: .any).willReturn()
        }
        let accessibility = accessibility()
        return routeDevices {
            $0.register(.apps) { apps }
            $0.register(.accessibility) { accessibility }
        }
    }

    @Test func `should launch the app and answer ok`() async throws {
        let ran = try await run(try LaunchCommand.parse(["--udid", "U", "--bundle-id", "com.x", "--relaunch"]),
                                on: launching())

        #expect(ran.exit == 0)
        #expect(ran.said == [#"{"ok":true,"action":"launch"}"#])
    }

    @Test func `should exit 1 answering why when the app won't launch`() async throws {
        let ran = try await run(try LaunchCommand.parse(["--udid", "U", "--bundle-id", "com.x"]),
                                on: launching(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.said == [#"{"ok":false,"action":"launch","error":"refused"}"#])
    }

    @Test func `should exit 1 launching on a device that can't read its screen`() async throws {
        let apps = MockApps()
        let ran = try await run(try LaunchCommand.parse(["--udid", "U", "--bundle-id", "com.x"]),
                                on: routeDevices { $0.register(.apps) { apps } })

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do accessibility"])
    }

    // MARK: - fill

    private func filling() -> any Devices {
        let accessibility = accessibility(), pasteboard = MockPasteboard(), touch = MockTouch()
        return routeDevices {
            $0.register(.accessibility) { accessibility }
            $0.register(.pasteboard) { pasteboard }
            $0.register(.touch) { touch }
        }
    }

    @Test func `should exit 1 answering why when the label names something that isn't a text field`() async throws {
        let ran = try await run(
            try FillCommand.parse(["--udid", "U", "--label", "Sign In", "--text", "hi", "--no-then-describe-ui"]),
            on: filling())

        #expect(ran.exit == 1)
        #expect(ran.said.first?.contains(#""ok":false"#) == true)
    }

    @Test func `should exit 1 filling on a device with nothing to type with`() async throws {
        let accessibility = accessibility(), pasteboard = MockPasteboard()
        let ran = try await run(
            try FillCommand.parse(["--udid", "U", "--label", "Name", "--text", "hi"]),
            on: routeDevices {
                $0.register(.accessibility) { accessibility }
                $0.register(.pasteboard) { pasteboard }
            })

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do touch"])
    }

    // MARK: - paste

    private func pasting(failing: Bool = false, lands: Bool = true) -> any Devices {
        let pasteboard = MockPasteboard()
        if failing {
            given(pasteboard).setText(.any).willThrow(Refused())
        } else {
            given(pasteboard).setText(.any).willReturn()
        }
        let touch = MockTouch(), key = MockKey()
        given(key).key(.any, modifiers: .any, duration: .any).willReturn(lands)
        return routeDevices {
            $0.register(.pasteboard) { pasteboard }
            $0.register(.touch) { touch }
            $0.register(.key) { key }
        }
    }

    @Test func `should set the pasteboard and press paste`() async throws {
        let ran = try await run(try PasteCommand.parse(["--udid", "U", "--text", "héllo"]), on: pasting())

        #expect(ran.exit == 0)
        #expect(ran.said == [#"{"ok":true,"action":"paste"}"#])
    }

    @Test func `should exit 1 answering not ok when the paste keystroke does not land`() async throws {
        let ran = try await run(try PasteCommand.parse(["--udid", "U", "--text", "x"]), on: pasting(lands: false))

        #expect(ran.exit == 1)
        #expect(ran.said == [#"{"ok":false,"action":"paste"}"#])
    }

    @Test func `should exit 1 when the pasteboard can't be set`() async throws {
        let ran = try await run(try PasteCommand.parse(["--udid", "U", "--text", "x", "--no-press"]),
                                on: pasting(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["paste failed: refused"])
    }

    @Test func `should exit 1 pasting on a device without a pasteboard`() async throws {
        let ran = try await run(try PasteCommand.parse(["--udid", "U", "--text", "x"]), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do pasteboard"])
    }

    // MARK: - describe-ui

    private func describing(tree: AXNode?) -> any Devices {
        let accessibility = accessibility(tree: tree)
        return routeDevices { $0.register(.accessibility) { accessibility } }
    }

    @Test func `should answer the screen's tree as JSON`() async throws {
        let ran = try await run(try DescribeUICommand.parse(["--udid", "U"]), on: describing(tree: Self.tree))

        #expect(ran.exit == 0)
        #expect(ran.said.count == 1)
        #expect(ran.said.first?.contains("Sign In") == true)
    }

    @Test func `should write the screen's tree to the file given`() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("describe-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let ran = try await run(try DescribeUICommand.parse(["--udid", "U", "-o", file.path]),
                                on: describing(tree: Self.tree))

        #expect(ran.said.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Sign In"))
    }

    @Test func `should exit 1 when the device describes no UI`() async throws {
        let ran = try await run(try DescribeUICommand.parse(["--udid", "U"]), on: describing(tree: nil))

        #expect(ran.exit == 1)
        #expect(ran.told == ["describe-ui: no accessibility data (device not ready, or no frontmost app)"])
    }

    @Test func `should exit 1 describing a device that can't read its screen`() async throws {
        let ran = try await run(try DescribeUICommand.parse(["--udid", "U"]), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do accessibility"])
    }
}
