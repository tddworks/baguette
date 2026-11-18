import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// Each one-shot gesture command run against the devices a test hands it:
/// the answer it prints, and the exit status that answer earns.
@Suite("Gesture commands run")
struct GestureCommandsRunTests {

    private let point = ["--width", "390", "--height", "844"]

    /// A device whose fingers, buttons and keys all land — or none do.
    private func screen(lands: Bool = true, tree: AXNode? = nil) -> any Devices {
        let touch = MockTouch()
        given(touch).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(lands)
        given(touch).swipe(from: .any, to: .any, size: .any, duration: .any).willReturn(lands)
        given(touch).touch1(phase: .any, at: .any, size: .any, edge: .any).willReturn(lands)
        given(touch).twoFingerPath(start1: .any, end1: .any, start2: .any, end2: .any, size: .any, duration: .any)
            .willReturn(lands)
        let press = MockPress()
        given(press).button(.any, duration: .any).willReturn(lands)
        given(press).available.willReturn([.navigation(.home), .hardware(.lock)])
        let key = MockKey()
        given(key).key(.any, modifiers: .any, duration: .any).willReturn(lands)
        let accessibility = MockAccessibility()
        given(accessibility).describeAll().willReturn(tree)
        given(accessibility).glance().willReturn(tree)
        given(accessibility).wake().willReturn()
        given(accessibility).press(.any).willReturn(lands)
        return routeDevices {
            $0.register(.touch) { touch }
            $0.register(.press) { press }
            $0.register(.key) { key }
            $0.register(.accessibility) { accessibility }
        }
    }

    // MARK: - tap

    @Test func `should answer ok when a tap at the point given lands`() async throws {
        let ran = try await run(try TapCommand.parse(["--udid", "U", "--x", "10", "--y", "20"] + point), on: screen())

        #expect(ran.exit == 0)
        #expect(ran.said == [#"{"ok":true,"action":"tap"}"#])
    }

    @Test func `should exit 1 answering not ok when the tap does not land`() async throws {
        let ran = try await run(try TapCommand.parse(["--udid", "U", "--x", "10", "--y", "20"] + point),
                                on: screen(lands: false))

        #expect(ran.exit == 1)
        #expect(ran.said == [#"{"ok":false,"action":"tap"}"#])
    }

    @Test func `should exit 1 before asking any device when the edge is unknown`() async throws {
        let ran = try await run(
            try TapCommand.parse(["--udid", "U", "--x", "0", "--y", "0", "--edge", "middle"] + point), on: screen())

        #expect(ran.exit == 1)
        #expect(ran.told == ["Unknown edge: middle (allowed: \(DeviceEdge.allowed))"])
    }

    @Test func `should exit 1 when no device has the udid`() async throws {
        let ran = try await run(try TapCommand.parse(["--udid", "NOPE", "--x", "1", "--y", "2"] + point), on: screen())

        #expect(ran.exit == 1)
        #expect(ran.told == ["Device NOPE not found"])
    }

    @Test func `should exit 1 when the device has nothing to touch`() async throws {
        let ran = try await run(try TapCommand.parse(["--udid", "U", "--x", "1", "--y", "2"] + point),
                                on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do touch"])
    }

    @Test func `should exit 1 describing nothing when a then-describe tap does not land`() async throws {
        let ran = try await run(
            try TapCommand.parse(["--udid", "U", "--x", "1", "--y", "2", "--then-describe-ui"] + point),
            on: screen(lands: false))

        #expect(ran.exit == 1)
        #expect(ran.said == [#"{"ok":false,"action":"tap"}"#])
    }

    @Test func `should exit 1 when a label press can't read the device's screen`() async throws {
        let touch = MockTouch()
        let ran = try await run(try TapCommand.parse(["--udid", "U", "--label", "Sign In"]),
                                on: routeDevices { $0.register(.touch) { touch } })

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do accessibility"])
    }

    @Test func `should press the element a label names`() async throws {
        let button = AXNode(role: "AXButton", label: "Sign In", frame: Rect(origin: Point(x: 10, y: 10), size: Size(width: 100, height: 44)))
        let tree = AXNode(role: "AXApplication", frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 390, height: 844)), children: [button])

        let ran = try await run(try TapCommand.parse(["--udid", "U", "--label", "Sign In"]), on: screen(tree: tree))

        #expect(ran.exit == 0)
        #expect(ran.said.first?.contains(#""ok":true"#) == true)
    }

    // MARK: - double-tap, swipe, pinch, pan

    @Test func `should answer ok when a double tap lands`() async throws {
        let ran = try await run(
            try DoubleTapCommand.parse(["--udid", "U", "--x", "1", "--y", "2", "--interval", "0", "--duration", "0"]
                + point),
            on: screen())

        #expect(ran.said == [#"{"ok":true,"action":"double-tap"}"#])
    }

    @Test func `should exit 1 when a double tap does not land`() async throws {
        let ran = try await run(
            try DoubleTapCommand.parse(["--udid", "U", "--x", "1", "--y", "2"] + point), on: screen(lands: false))

        #expect(ran.exit == 1)
    }

    private let swipe = ["--start-x", "1", "--start-y", "2", "--end-x", "3", "--end-y", "4"]

    @Test func `should answer ok when a swipe lands`() async throws {
        let ran = try await run(try SwipeCommand.parse(["--udid", "U"] + swipe + point), on: screen())

        #expect(ran.said == [#"{"ok":true,"action":"swipe"}"#])
    }

    @Test func `should exit 1 describing nothing when a then-describe swipe does not land`() async throws {
        let ran = try await run(try SwipeCommand.parse(["--udid", "U", "--then-describe-ui"] + swipe + point),
                                on: screen(lands: false))

        #expect(ran.exit == 1)
        #expect(ran.said == [#"{"ok":false,"action":"swipe"}"#])
    }

    @Test func `should answer ok when a pinch lands`() async throws {
        let ran = try await run(
            try PinchCommand.parse(["--udid", "U", "--cx", "100", "--cy", "100", "--start-spread", "10",
                                    "--end-spread", "50"] + point),
            on: screen())

        #expect(ran.said == [#"{"ok":true,"action":"pinch"}"#])
    }

    @Test func `should answer ok when a pan lands`() async throws {
        let ran = try await run(
            try PanCommand.parse(["--udid", "U", "--x1", "1", "--y1", "2", "--x2", "3", "--y2", "4",
                                  "--dx", "5", "--dy", "6"] + point),
            on: screen())

        #expect(ran.said == [#"{"ok":true,"action":"pan"}"#])
    }

    // MARK: - press, key, type

    @Test func `should answer ok when a button press lands`() async throws {
        let ran = try await run(try PressCommand.parse(["--udid", "U", "--button", "home"]), on: screen())

        #expect(ran.said == [#"{"ok":true,"action":"press"}"#])
    }

    @Test func `should exit 1 naming the buttons when the button is unknown`() async throws {
        let ran = try await run(try PressCommand.parse(["--udid", "U", "--button", "turbo"]), on: screen())

        #expect(ran.exit == 1)
        #expect(ran.told == ["Unknown button: turbo (allowed: \(ButtonPress.allowed))"])
    }

    @Test func `should answer ok when a keystroke lands`() async throws {
        let ran = try await run(try KeyCommand.parse(["--udid", "U", "--code", "KeyA", "--modifiers", "shift"]),
                                on: screen())

        #expect(ran.said == [#"{"ok":true,"action":"key"}"#])
    }

    @Test func `should exit 1 when the key code is unknown`() async throws {
        let ran = try await run(try KeyCommand.parse(["--udid", "U", "--code", "KeyÆ"]), on: screen())

        #expect(ran.exit == 1)
        #expect(ran.told == ["Unknown key code: KeyÆ"])
    }

    @Test func `should answer ok when typed text lands`() async throws {
        let ran = try await run(try TypeCommand.parse(["--udid", "U", "--text", "hi"]), on: screen())

        #expect(ran.said == [#"{"ok":true,"action":"type"}"#])
    }

    @Test func `should exit 1 when the text can't be typed`() async throws {
        let ran = try await run(try TypeCommand.parse(["--udid", "U", "--text", "héllo"]), on: screen())

        #expect(ran.exit == 1)
        #expect(ran.told.first?.hasPrefix("Cannot type:") == true)
    }
}
