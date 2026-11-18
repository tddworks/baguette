import ArgumentParser
import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// What each one-shot gesture command makes of its command line, and how
/// it answers — everything `run()` decides before and after the device.
@Suite("Gesture commands")
struct GestureCommandsTests {

    // MARK: - answer line

    @Test func `should answer a gesture that landed with ok and its action`() {
        #expect(GestureAnswer.line(ok: true, action: "tap") == #"{"ok":true,"action":"tap"}"#)
    }

    @Test func `should answer a gesture that did not land with not ok`() {
        #expect(GestureAnswer.line(ok: false, action: "swipe") == #"{"ok":false,"action":"swipe"}"#)
    }

    @Test func `should exit cleanly only when a describe-ui answer starts ok`() {
        #expect(GestureAnswer.succeeded(#"{"ok":true,"changed":false}"#))
        #expect(!GestureAnswer.succeeded(#"{"ok":false,"error":"x"}"#))
    }

    @Test func `should exit cleanly when a label press answer says ok anywhere`() {
        #expect(GestureAnswer.pressed(#"{"action":"tap","ok":true}"#))
        #expect(!GestureAnswer.pressed(#"{"ok":false}"#))
    }

    // MARK: - tap

    @Test func `should tap the point given, held for the duration given`() throws {
        let cmd = try TapCommand.parse(
            ["--udid", "U", "--x", "10", "--y", "20", "--width", "390", "--height", "844", "--duration", "0.2"])

        #expect(try cmd.gesture() == Tap(
            at: Point(x: 10, y: 20), size: Size(width: 390, height: 844), duration: 0.2))
    }

    @Test func `should tap on a screen edge when one is named`() throws {
        let cmd = try TapCommand.parse(
            ["--udid", "U", "--x", "0", "--y", "400", "--width", "390", "--height", "844", "--edge", "left"])

        #expect(try cmd.gesture().edge == .left)
    }

    @Test func `should refuse a tap on an edge that doesn't exist, naming the allowed ones`() throws {
        let cmd = try TapCommand.parse(
            ["--udid", "U", "--x", "0", "--y", "0", "--width", "1", "--height", "1", "--edge", "middle"])

        #expect(throws: ArgumentRefusal("Unknown edge: middle (allowed: \(DeviceEdge.allowed))")) {
            try cmd.gesture()
        }
    }

    @Test func `should refuse a tap that names neither an element nor a whole point`() {
        #expect(throws: (any Error).self) {
            try TapCommand.parse(["--udid", "U", "--x", "1", "--y", "2"])
        }
    }

    @Test func `should press an element by label with every flag carried on the line`() throws {
        let cmd = try TapCommand.parse(
            ["--udid", "U", "--label", "Sign In", "--edge", "left", "--touch", "--then-describe-ui"])

        let line = try #require(
            JSONSerialization.jsonObject(with: Data(cmd.labelLine.utf8)) as? [String: Any])
        #expect(line["type"] as? String == "tap")
        #expect(line["label"] as? String == "Sign In")
        #expect(line["duration"] as? Double == 0.05)
        #expect(line["edge"] as? String == "left")
        #expect(line["touch"] as? Bool == true)
        #expect(line["then_describe_ui"] as? Bool == true)
    }

    @Test func `should press an element by label with only its duration when no flag is given`() throws {
        let cmd = try TapCommand.parse(["--udid", "U", "--label", "OK"])

        let line = try #require(
            JSONSerialization.jsonObject(with: Data(cmd.labelLine.utf8)) as? [String: Any])
        #expect(Set(line.keys) == ["type", "label", "duration"])
    }

    // MARK: - swipe, pinch, pan

    @Test func `should swipe from the start point to the end point`() throws {
        let cmd = try SwipeCommand.parse([
            "--udid", "U", "--start-x", "10", "--start-y", "700", "--end-x", "10", "--end-y", "100",
            "--width", "390", "--height", "844",
        ])

        #expect(cmd.gesture == Swipe(
            from: Point(x: 10, y: 700), to: Point(x: 10, y: 100),
            size: Size(width: 390, height: 844), duration: 0.25))
    }

    @Test func `should pinch around the centre from one spread to another`() throws {
        let cmd = try PinchCommand.parse([
            "--udid", "U", "--cx", "195", "--cy", "422", "--start-spread", "50", "--end-spread", "200",
            "--width", "390", "--height", "844",
        ])

        #expect(cmd.gesture == Pinch(
            center: Point(x: 195, y: 422), startSpread: 50, endSpread: 200,
            size: Size(width: 390, height: 844), duration: 0.6))
    }

    @Test func `should pan two fingers by the same offset`() throws {
        let cmd = try PanCommand.parse([
            "--udid", "U", "--x1", "100", "--y1", "400", "--x2", "200", "--y2", "400",
            "--dx", "0", "--dy=-150", "--width", "390", "--height", "844",
        ])

        #expect(cmd.gesture == Pan(
            first: Point(x: 100, y: 400), second: Point(x: 200, y: 400), dx: 0, dy: -150,
            size: Size(width: 390, height: 844), duration: 0.5))
    }

    // MARK: - press

    @Test func `should press the button named, held for the duration given`() throws {
        let cmd = try PressCommand.parse(["--udid", "U", "--button", "home", "--duration", "1"])

        #expect(try cmd.gesture() == ButtonPress(button: .navigation(.home), duration: 1))
    }

    @Test func `should refuse a button that doesn't exist, naming the allowed ones`() throws {
        let cmd = try PressCommand.parse(["--udid", "U", "--button", "turbo"])

        #expect(throws: ArgumentRefusal("Unknown button: turbo (allowed: \(ButtonPress.allowed))")) {
            try cmd.gesture()
        }
    }

    // MARK: - key

    @Test func `should press a key with every modifier named`() throws {
        let cmd = try KeyCommand.parse(["--udid", "U", "--code", "KeyA", "--modifiers", "shift, command"])

        #expect(try cmd.keystroke() == Keystroke(
            key: try #require(KeyboardKey.from(wireCode: "KeyA")), modifiers: [.shift, .command]))
    }

    @Test func `should press a key with no modifiers when none are named`() throws {
        let cmd = try KeyCommand.parse(["--udid", "U", "--code", "Enter"])

        #expect(try cmd.keystroke().modifiers.isEmpty)
    }

    @Test func `should refuse a key code it doesn't know`() throws {
        let cmd = try KeyCommand.parse(["--udid", "U", "--code", "KeyÄ"])

        #expect(throws: ArgumentRefusal("Unknown key code: KeyÄ")) { try cmd.keystroke() }
    }

    @Test func `should refuse a modifier it doesn't know, naming the allowed ones`() throws {
        let cmd = try KeyCommand.parse(["--udid", "U", "--code", "KeyA", "--modifiers", "shift,hyper"])

        #expect(throws: ArgumentRefusal("Unknown modifier: hyper (allowed: shift | control | option | command)")) {
            try cmd.keystroke()
        }
    }

    // MARK: - type

    @Test func `should type the text given`() throws {
        let cmd = try TypeCommand.parse(["--udid", "U", "--text", "hello"])

        #expect(try cmd.gesture() == TypeText.parse(["text": "hello"]))
    }

    @Test func `should refuse text it can't type, saying why`() throws {
        let cmd = try TypeCommand.parse(["--udid", "U", "--text", "héllo"])

        let refusal = #expect(throws: ArgumentRefusal.self) { try cmd.gesture() }
        #expect(refusal?.message.hasPrefix("Cannot type: ") == true)
    }

    // MARK: - the role a gesture needs

    @Test func `should hand a gesture the role its device registered`() throws {
        let touch = MockTouch()
        let device = commandDevice { $0.register(.touch) { touch } }

        let role = try device.role(for: Tap(at: Point(x: 1, y: 1), size: Size(width: 2, height: 2), duration: 0))

        #expect(role as AnyObject === touch)
    }

    @Test func `should refuse a gesture when its device can't take it, naming the device`() {
        let device = commandDevice(name: "han's iPhone")

        #expect(throws: DeviceError.unable(ability: "touch", device: "han's iPhone")) {
            try device.role(for: Tap(at: Point(x: 1, y: 1), size: Size(width: 2, height: 2), duration: 0))
        }
    }
}

/// One device with only the abilities `register` gives it.
func commandDevice(
    name: String = "iPhone 17", state: DeviceState = .ready,
    _ register: (inout Abilities) -> Void = { _ in }
) -> any Device {
    var abilities = Abilities(device: name)
    register(&abilities)
    let device = MockDevice()
    given(device).id.willReturn("U")
    given(device).name.willReturn(name)
    given(device).state.willReturn(state)
    given(device).kind.willReturn(DeviceKind(platform: .iOS, reality: .simulated, model: name))
    given(device).abilities.willReturn(abilities)
    return device
}
