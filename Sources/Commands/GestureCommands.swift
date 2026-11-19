import BaguetteDevice
import ArgumentParser
import Foundation

/// The device a gesture goes to, from every family — or exit 1 saying no
/// source knows it.
private func resolve(udid: String, deviceSet: String?) throws -> any Device {
    var options = DeviceOption()
    options.udid = udid
    options.deviceSet = deviceSet
    return try options.device()
}

/// A command-line value the command can't act on, in the words it logs
/// before exiting 1 — decided before any device is asked.
struct ArgumentRefusal: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// How a one-shot gesture command answers on stdout, and which answers
/// exit 0.
enum GestureAnswer {
    static func line(ok: Bool, action: String) -> String {
        "{\"ok\":\(ok),\"action\":\"\(action)\"}"
    }

    /// A `--then-describe-ui` answer: success leads the object.
    static func succeeded(_ answer: String) -> Bool { answer.hasPrefix(#"{"ok":true"#) }

    /// A `--label` press answer: success anywhere in it.
    static func pressed(_ answer: String) -> Bool { answer.contains(#""ok":true"#) }
}

/// Its value, or exit 1 telling why: a refusal in its own words.
private func orExitNow<T>(_ body: () throws -> T) throws -> T {
    do { return try body() } catch let refusal as ArgumentRefusal {
        tell(refusal.message)
        throw ExitCode.failure
    } catch {
        tell("\(error)")
        throw ExitCode.failure
    }
}

extension Device {
    /// The role `gesture` is an act of, or a refusal naming the device:
    /// the ability it lacks, or what the act needs of it (a navigation).
    func role<G: Gesture>(for gesture: G) throws -> G.Role {
        let role = try require(G.ability)
        if let missing = gesture.missing(from: role) {
            throw DeviceError.unable(ability: missing, device: name)
        }
        return role
    }
}

private extension Device {
    /// Its gestures, or exit 1 saying it can't take them (or isn't ready).
    func screenInput() throws -> Abilities { try orExitNow { try input() } }
    /// The role `gesture` is an act of, or exit 1 saying it can't take it.
    func roleOrExit<G: Gesture>(for gesture: G) throws -> G.Role { try orExitNow { try role(for: gesture) } }
    /// Its fingers, or exit 1.
    func touch() throws -> any Touch { try orExitNow { try require(.touch) } }
    /// What is on its screen, for `--label` and `--then-describe-ui`.
    func accessibility() throws -> any Accessibility { try orExitNow { try require(.accessibility) } }
}

/// Answer whether the gesture landed; one that didn't exits 1.
private func runOrExit(_ ok: Bool, action: String) throws {
    say(GestureAnswer.line(ok: ok, action: action))
    if !ok { throw ExitCode.failure }
}

/// Answer `result`; one that isn't `success` exits 1.
private func answer(_ result: String, success: (String) -> Bool) throws {
    say(result)
    if !success(result) { throw ExitCode.failure }
}

// MARK: - tap

struct TapCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tap",
        abstract: "Press an element by name, or tap a point",
        discussion: "--label presses through accessibility and reaches a control wherever it is. --touch uses a real finger, to test what a user can reach. Giving a point needs all of --x, --y, --width and --height."
    )

    @OptionGroup var options: DeviceOption
    @Option(help: "The element to press, by its name from the answer's affordances, part of its label, or identifier. Replaces --x, --y, --width and --height.")
    var label: String?
    @Option var x: Double?
    @Option var y: Double?
    @Option var width: Double?
    @Option var height: Double?
    @Option(help: "Hold duration in seconds") var duration: Double = 0.05
    @Option(help: "Screen edge the tap lands on: \(DeviceEdge.allowed). Omit for an interior tap.")
    var edge: String?
    @Flag(help: "With --label, use a real finger at the element, to test what a user can reach, or when a press has no effect.")
    var touch = false
    @Flag(help: "Wait for the screen to settle, then answer with whether it changed, what can be done next and what the screen says.")
    var thenDescribeUI = false

    func validate() throws {
        guard label == nil else { return }
        guard x != nil, y != nil, width != nil, height != nil else {
            throw ValidationError("Name an element with --label, or give --x, --y, --width and --height.")
        }
    }

    /// The tap at the point given — refused for an edge that isn't one.
    /// `validate()` has already required the whole point.
    func gesture() throws -> Tap {
        var landing: DeviceEdge?
        if let edge {
            guard let parsed = DeviceEdge(rawValue: edge) else {
                throw ArgumentRefusal("Unknown edge: \(edge) (allowed: \(DeviceEdge.allowed))")
            }
            landing = parsed
        }
        return Tap(at: Point(x: x ?? 0, y: y ?? 0), size: Size(width: width ?? 0, height: height ?? 0),
                   duration: duration, edge: landing)
    }

    /// The `--label` press as the one wire line `LabelTap` reads.
    var labelLine: String {
        var envelope: [String: Any] = ["type": Tap.wireType, "label": label ?? "", "duration": duration]
        if let edge { envelope["edge"] = edge }
        if thenDescribeUI { envelope["then_describe_ui"] = true }
        if touch { envelope["touch"] = true }
        let bytes = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        return String(decoding: bytes, as: UTF8.self)
    }

    func run() throws {
        if label != nil { return try runByLabel() }
        let gesture = try orExitNow { try gesture() }
        let sim = try resolve(udid: options.udid, deviceSet: options.deviceSet)
        if thenDescribeUI {
            let role = try sim.roleOrExit(for: gesture)
            let result = ThenDescribe.perform(
                action: "tap", at: gesture.at, accessibility: try sim.accessibility(),
                affordances: options.affordanceStyle
            ) {
                gesture.execute(on: role)
            }
            return try answer(result, success: GestureAnswer.succeeded)
        }
        try runOrExit(gesture.execute(on: try sim.roleOrExit(for: gesture)), action: "tap")
    }

    private func runByLabel() throws {
        let sim = try resolve(udid: options.udid, deviceSet: options.deviceSet)
        let dispatcher = GestureDispatcher(input: try sim.screenInput())
        let result = LabelTap.dispatch(
            line: labelLine,
            accessibility: try sim.accessibility(),
            gesture: { dispatcher.dispatch(line: $0) },
            affordances: options.affordanceStyle
        ) ?? #"{"ok":false}"#
        try answer(result, success: GestureAnswer.pressed)
    }
}

// MARK: - double-tap

/// One-shot CLI for a native iOS double-tap at a single coordinate.
///
/// The browser / `baguette input` paths already cover this by sending
/// four `touch1-down` / `touch1-up` lines on one long-lived connection —
/// see `docs/features/double-tap/design.md`. What this command adds is the
/// same recipe inside a **single process**, because two back-to-back
/// `baguette tap` invocations spend so long in process startup that
/// `UITapGestureRecognizer` times out between them.
///
/// Defaults (`duration` = 0.08 s, `interval` = 0.05 s) match the
/// known-working cadence captured in the WebSocket trace on issue #11.
struct DoubleTapCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "double-tap",
        abstract: "Two taps at one point — fires UITapGestureRecognizer / TapGesture(count: 2)"
    )

    @OptionGroup var options: DeviceOption
    @Option var x: Double
    @Option var y: Double
    @Option var width: Double
    @Option var height: Double
    @Option(help: "Gap between tap-1-up and tap-2-down, seconds")
    var interval: Double = 0.05
    @Option(help: "Hold duration per tap, seconds")
    var duration: Double = 0.08

    /// Sequence the four phased `Touch1` events that the iOS recognizer
    /// needs to aggregate into one double-tap. Lifted out of `run()` so
    /// tests can drive it with a `MockTouch` and a no-op sleep — the
    /// command body is otherwise unreachable in unit tests because it
    /// resolves a real `CoreSimulators` device.
    static func dispatch(
        at point: Point, size: Size, interval: Double, duration: Double,
        on touch: any Touch,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Bool {
        let down = Touch1(phase: .down, at: point, size: size, edge: nil)
        let up   = Touch1(phase: .up,   at: point, size: size, edge: nil)
        guard down.execute(on: touch) else { return false }
        sleep(duration)
        guard up.execute(on: touch) else { return false }
        sleep(interval)
        guard down.execute(on: touch) else { return false }
        sleep(duration)
        return up.execute(on: touch)
    }

    func run() throws {
        let sim = try resolve(udid: options.udid, deviceSet: options.deviceSet)
        let ok = Self.dispatch(
            at: Point(x: x, y: y),
            size: Size(width: width, height: height),
            interval: interval, duration: duration,
            on: try sim.touch()
        )
        try runOrExit(ok, action: "double-tap")
    }
}

// MARK: - swipe

struct SwipeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swipe",
        abstract: "One-finger drag from start to end"
    )

    @OptionGroup var options: DeviceOption
    @Option var startX: Double
    @Option var startY: Double
    @Option var endX: Double
    @Option var endY: Double
    @Option var width: Double
    @Option var height: Double
    @Option var duration: Double = 0.25
    @Flag(help: "Wait for the screen to settle, then answer with whether it moved, what can be done next and what the screen says.")
    var thenDescribeUI = false

    var gesture: Swipe {
        Swipe(
            from: Point(x: startX, y: startY),
            to:   Point(x: endX, y: endY),
            size: Size(width: width, height: height),
            duration: duration
        )
    }

    func run() throws {
        let sim = try resolve(udid: options.udid, deviceSet: options.deviceSet)
        let gesture = self.gesture
        if thenDescribeUI {
            let role = try sim.roleOrExit(for: gesture)
            let result = ThenDescribe.perform(
                action: "swipe", unchangedHint: ThenDescribe.swipeUnchanged, accessibility: try sim.accessibility(),
                affordances: options.affordanceStyle
            ) {
                gesture.execute(on: role)
            }
            return try answer(result, success: GestureAnswer.succeeded)
        }
        try runOrExit(gesture.execute(on: try sim.roleOrExit(for: gesture)), action: "swipe")
    }
}

// MARK: - pinch

struct PinchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pinch",
        abstract: "Two-finger pinch / spread around a centre point"
    )

    @OptionGroup var options: DeviceOption
    @Option var cx: Double
    @Option var cy: Double
    @Option var startSpread: Double
    @Option var endSpread: Double
    @Option var width: Double
    @Option var height: Double
    @Option var duration: Double = 0.6

    var gesture: Pinch {
        Pinch(
            center: Point(x: cx, y: cy),
            startSpread: startSpread,
            endSpread: endSpread,
            size: Size(width: width, height: height),
            duration: duration
        )
    }

    func run() throws {
        let sim = try resolve(udid: options.udid, deviceSet: options.deviceSet)
        try runOrExit(gesture.execute(on: try sim.roleOrExit(for: gesture)), action: "pinch")
    }
}

// MARK: - pan

struct PanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pan",
        abstract: "Two-finger parallel drag"
    )

    @OptionGroup var options: DeviceOption
    @Option var x1: Double
    @Option var y1: Double
    @Option var x2: Double
    @Option var y2: Double
    @Option var dx: Double
    @Option var dy: Double
    @Option var width: Double
    @Option var height: Double
    @Option var duration: Double = 0.5

    var gesture: Pan {
        Pan(
            first:  Point(x: x1, y: y1),
            second: Point(x: x2, y: y2),
            dx: dx, dy: dy,
            size: Size(width: width, height: height),
            duration: duration
        )
    }

    func run() throws {
        let sim = try resolve(udid: options.udid, deviceSet: options.deviceSet)
        try runOrExit(gesture.execute(on: try sim.roleOrExit(for: gesture)), action: "pan")
    }
}

// MARK: - press

struct PressCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "press",
        abstract: "Press-and-release a device button (\(ButtonPress.allowed))"
    )

    @OptionGroup var options: DeviceOption
    @Option(help: "Device button: \(ButtonPress.allowed)") var button: String
    @Option(help: "Hold duration in seconds (0 = short tap)") var duration: Double = 0

    func gesture() throws -> ButtonPress {
        guard let device = DeviceButton(rawValue: button) else {
            throw ArgumentRefusal("Unknown button: \(button) (allowed: \(ButtonPress.allowed))")
        }
        return ButtonPress(button: device, duration: duration)
    }

    func run() throws {
        let gesture = try orExitNow { try gesture() }
        let sim = try resolve(udid: options.udid, deviceSet: options.deviceSet)
        try runOrExit(gesture.execute(on: try sim.roleOrExit(for: gesture)), action: "press")
    }
}

// MARK: - key

struct KeyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key",
        abstract: "Press a single keyboard key with optional modifiers"
    )

    @OptionGroup var options: DeviceOption
    @Option(help: "W3C KeyboardEvent.code — KeyA-Z, Digit0-9, Enter, Escape, Backspace, Tab, Space, Arrow*, common punctuation")
    var code: String
    @Option(help: "Comma-separated modifiers (shift,control,option,command)")
    var modifiers: String = ""
    @Option(help: "Hold duration in seconds (0 = short tap)") var duration: Double = 0

    func keystroke() throws -> Keystroke {
        guard let key = KeyboardKey.from(wireCode: code) else {
            throw ArgumentRefusal("Unknown key code: \(code)")
        }
        var mods: Set<KeyModifier> = []
        for raw in modifiers.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) })
        where !raw.isEmpty {
            guard let m = KeyModifier(rawValue: raw) else {
                throw ArgumentRefusal("Unknown modifier: \(raw) (allowed: shift | control | option | command)")
            }
            mods.insert(m)
        }
        return Keystroke(key: key, modifiers: mods, duration: duration)
    }

    func run() throws {
        let keystroke = try orExitNow { try keystroke() }
        let sim = try resolve(udid: options.udid, deviceSet: options.deviceSet)
        try runOrExit(keystroke.execute(on: try sim.roleOrExit(for: keystroke)), action: "key")
    }
}

// MARK: - type

struct TypeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type a string of US-ASCII text into the focused field"
    )

    @OptionGroup var options: DeviceOption
    @Option(help: "Text to type. Non-ASCII / dead-key characters are rejected.")
    var text: String

    func gesture() throws -> TypeText {
        do {
            return try TypeText.parse(["text": text])
        } catch let error as GestureError {
            throw ArgumentRefusal("Cannot type: \(error.message)")
        } catch {
            throw ArgumentRefusal("Cannot type: \(error)")
        }
    }

    func run() throws {
        let gesture = try orExitNow { try gesture() }
        let sim = try resolve(udid: options.udid, deviceSet: options.deviceSet)
        try runOrExit(gesture.execute(on: try sim.roleOrExit(for: gesture)), action: "type")
    }
}
