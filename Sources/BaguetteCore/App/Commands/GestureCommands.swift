import ArgumentParser
import Foundation

/// Resolve a simulator by UDID + device set, or exit(1) with an error log.
private func resolve(udid: String, deviceSet: String?) -> Simulator {
    let simulators = CoreSimulators(deviceSetPath: deviceSet)
    guard let simulator = simulators.find(udid: udid) else {
        log("Device \(udid) not found")
        Foundation.exit(1)
    }
    return simulator
}

private func runOrExit(_ ok: Bool, action: String) {
    print("{\"ok\":\(ok),\"action\":\"\(action)\"}")
    Foundation.exit(ok ? 0 : 1)
}

// MARK: - tap

struct TapCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tap",
        abstract: "Single tap at a point"
    )

    @OptionGroup var options: DeviceOption
    @Option var x: Double
    @Option var y: Double
    @Option var width: Double
    @Option var height: Double
    @Option(help: "Hold duration in seconds") var duration: Double = 0.05

    func run() {
        let sim = resolve(udid: options.udid, deviceSet: options.deviceSet)
        let gesture = Tap(at: Point(x: x, y: y), size: Size(width: width, height: height), duration: duration)
        runOrExit(gesture.execute(on: sim.input()), action: "tap")
    }
}

// MARK: - double-tap

/// One-shot CLI for a native iOS double-tap at a single coordinate.
///
/// The browser / `baguette input` paths already cover this by sending
/// four `touch1-down` / `touch1-up` lines on one long-lived connection —
/// see `docs/features/double-tap.md`. What this command adds is the
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
    /// tests can drive it with a `MockInput` and a no-op sleep — the
    /// command body is otherwise unreachable in unit tests because it
    /// resolves a real `CoreSimulators` device.
    static func dispatch(
        at point: Point, size: Size, interval: Double, duration: Double,
        on input: any Input,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Bool {
        let down = Touch1(phase: .down, at: point, size: size, edge: nil)
        let up   = Touch1(phase: .up,   at: point, size: size, edge: nil)
        guard down.execute(on: input) else { return false }
        sleep(duration)
        guard up.execute(on: input) else { return false }
        sleep(interval)
        guard down.execute(on: input) else { return false }
        sleep(duration)
        return up.execute(on: input)
    }

    func run() {
        let sim = resolve(udid: options.udid, deviceSet: options.deviceSet)
        let ok = Self.dispatch(
            at: Point(x: x, y: y),
            size: Size(width: width, height: height),
            interval: interval, duration: duration,
            on: sim.input()
        )
        runOrExit(ok, action: "double-tap")
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

    func run() {
        let sim = resolve(udid: options.udid, deviceSet: options.deviceSet)
        let gesture = Swipe(
            from: Point(x: startX, y: startY),
            to:   Point(x: endX, y: endY),
            size: Size(width: width, height: height),
            duration: duration
        )
        runOrExit(gesture.execute(on: sim.input()), action: "swipe")
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

    func run() {
        let sim = resolve(udid: options.udid, deviceSet: options.deviceSet)
        let gesture = Pinch(
            center: Point(x: cx, y: cy),
            startSpread: startSpread,
            endSpread: endSpread,
            size: Size(width: width, height: height),
            duration: duration
        )
        runOrExit(gesture.execute(on: sim.input()), action: "pinch")
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

    func run() {
        let sim = resolve(udid: options.udid, deviceSet: options.deviceSet)
        let gesture = Pan(
            first:  Point(x: x1, y: y1),
            second: Point(x: x2, y: y2),
            dx: dx, dy: dy,
            size: Size(width: width, height: height),
            duration: duration
        )
        runOrExit(gesture.execute(on: sim.input()), action: "pan")
    }
}

// MARK: - press

struct PressCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "press",
        abstract: "Press-and-release a hardware button (\(Press.allowed))"
    )

    @OptionGroup var options: DeviceOption
    @Option(help: "Hardware button: \(Press.allowed)") var button: String
    @Option(help: "Hold duration in seconds (0 = short tap)") var duration: Double = 0

    func run() {
        guard let device = DeviceButton(rawValue: button) else {
            log("Unknown button: \(button) (allowed: \(Press.allowed))")
            Foundation.exit(1)
        }
        let sim = resolve(udid: options.udid, deviceSet: options.deviceSet)
        let gesture = Press(button: device, duration: duration)
        runOrExit(gesture.execute(on: sim.input()), action: "press")
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

    func run() {
        guard let key = KeyboardKey.from(wireCode: code) else {
            log("Unknown key code: \(code)")
            Foundation.exit(1)
        }
        var mods: Set<KeyModifier> = []
        for raw in modifiers.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) })
        where !raw.isEmpty {
            guard let m = KeyModifier(rawValue: raw) else {
                log("Unknown modifier: \(raw) (allowed: shift | control | option | command)")
                Foundation.exit(1)
            }
            mods.insert(m)
        }
        let sim = resolve(udid: options.udid, deviceSet: options.deviceSet)
        runOrExit(
            key.press(modifiers: mods, duration: duration, on: sim.input()),
            action: "key"
        )
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

    func run() {
        let gesture: TypeText
        do {
            gesture = try TypeText.parse(["text": text])
        } catch let error as GestureError {
            log("Cannot type: \(error.message)")
            Foundation.exit(1)
        } catch {
            log("Cannot type: \(error)")
            Foundation.exit(1)
        }
        let sim = resolve(udid: options.udid, deviceSet: options.deviceSet)
        runOrExit(gesture.execute(on: sim.input()), action: "type")
    }
}
