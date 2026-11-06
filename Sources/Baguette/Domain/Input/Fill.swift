import Foundation

/// Make one named text field hold this text. Wire shape:
/// `{ "type": "fill", "label": "email", "text": "gary@example.com" }`.
///
/// `type` sends keys to whatever has focus and answers that it sent them. A fill finds
/// the field, clears it, enters the text, and answers with what the field shows.
///
/// Not a `Gesture`, for the reason `Paste` isn't: it needs the screen and the
/// pasteboard, not only `Input`. So it takes roles, and a `baguette input` session
/// passes the `Input` it has already bound to its plane.
struct Fill: Equatable, Sendable {
    static let wireType = "fill"

    struct Timing: Equatable, Sendable {
        var find: TimeInterval = 5
        var focus: TimeInterval = 1
        var readBack: TimeInterval = 1
        var poll: TimeInterval = 0.03
    }

    let label: String
    let text: String

    static func parse(_ dict: [String: Any]) throws -> Fill {
        Fill(label: try Field.requiredString(dict, "label"), text: try Field.requiredString(dict, "text"))
    }

    /// On the main actor because a press that can't focus the field falls back to a
    /// touch, and IndigoHID's touch messages read AppKit's thread-local state.
    @MainActor
    func execute(
        accessibility: any Accessibility,
        pasteboard: any Pasteboard,
        input: any Input,
        timing: Timing = Timing(),
        inputTaken: @Sendable () async -> Bool = { false }
    ) async -> FillOutcome {
        let outcome = await attempt(accessibility: accessibility, pasteboard: pasteboard, input: input, timing: timing)
        // Asked only after a miss: a fill that landed pays nothing for it.
        guard outcome.mayBeInputTaken, await inputTaken() else { return outcome }
        return .inputTaken(name: outcome.fieldName ?? label)
    }

    @MainActor
    private func attempt(
        accessibility: any Accessibility,
        pasteboard: any Pasteboard,
        input: any Input,
        timing: Timing
    ) async -> FillOutcome {
        let found = AXTarget.wait(
            for: label,
            glance: { try? accessibility.glance() },
            read: { try? accessibility.describeAll() },
            timeout: timing.find, poll: timing.poll)
        guard case .found(let node) = found.lookup else {
            return .unreachable(found.refusal(of: label) ?? AXTarget.Refusal(message: "nothing matches \(label)"))
        }
        guard let field = node.textField else { return .notATextField(name: node.offerName) }

        let name = field.name
        func current() -> TextField? { currentField(accessibility) }
        func waitUntil(_ limit: TimeInterval, _ done: () -> Bool) -> Bool {
            let start = Date()
            while true {
                if done() { return true }
                if Date().timeIntervalSince(start) >= limit { return false }
                Thread.sleep(forTimeInterval: timing.poll)
            }
        }
        func focused() -> Bool { current()?.isFocused == true }

        if !field.isFocused {
            // A touch first when the field is on screen: a press rewalks the whole tree
            // to find it, and there's no second `Pay` to fear in focusing a field.
            if let screen = found.screen, let point = node.touchPoint(on: screen) {
                let size = Size(width: screen.width, height: screen.height)
                _ = Tap(at: point, size: size, duration: 0.05).execute(on: input)
                if !waitUntil(timing.focus, focused) {
                    _ = try? accessibility.press(node)
                    guard waitUntil(timing.focus, focused) else { return .neverFocused(name: name) }
                }
            } else {
                _ = try? accessibility.press(node)
                guard waitUntil(timing.focus, focused) else { return .neverFocused(name: name) }
            }
        }

        guard clear(on: input) else { return .failed("couldn't send a key to \(name)") }
        guard !text.isEmpty else { return .cleared(name: name) }

        func paste() async -> FillOutcome? {
            do {
                let pressed = try await Paste(text: text).execute(pasteboard: pasteboard, input: input)
                return pressed ? nil : .failed("couldn't send a key to \(name)")
            } catch {
                return .failed("couldn't paste into \(name): \(error)")
            }
        }
        /// What the field reads as, once it shows the text or the wait runs out.
        func readBack() -> (field: TextField, reading: FieldReading)? {
            var last: (TextField, FieldReading)?
            _ = waitUntil(timing.readBack) {
                guard let field = current() else { return false }
                let reading = field.reading(of: text)
                last = (field, reading)
                return reading != .differs
            }
            return last
        }
        func outcome(_ result: (field: TextField, reading: FieldReading)?) -> FillOutcome {
            guard let result else { return .failed("\(name) is gone from the screen") }
            guard result.reading != .differs else {
                return .differs(name: name, shows: result.field.shows, wanted: result.field.wanted(text))
            }
            return .filled(name: name, shows: result.field.shows)
        }

        guard let typed = TypeText(typeable: text) else {
            if let failure = await paste() { return failure }
            return outcome(readBack())
        }
        guard typed.execute(on: input) else { return .failed("couldn't send a key to \(name)") }

        let first = readBack()
        // A password stays off the shared pasteboard while it can be typed.
        guard first?.reading != .exact, first?.field.isSecure != true else { return outcome(first) }

        // Autocorrect or smart punctuation may have changed the keys; a paste is taken
        // as it is. Safe to do once, unlike a tap: it leaves the same text in the field.
        guard clear(on: input) else { return .failed("couldn't send a key to \(name)") }
        if let failure = await paste() { return failure }
        return outcome(readBack())
    }

    /// The named field as it is now. The cheap glance first: only a field a sweep
    /// alone can see needs the full read.
    private func currentField(_ accessibility: any Accessibility) -> TextField? {
        func field(in tree: AXNode?) -> TextField? {
            guard let tree, case .found(let node) = AXTarget.find(label, in: tree) else { return nil }
            return node.textField
        }
        return field(in: try? accessibility.glance()) ?? field(in: try? accessibility.describeAll())
    }

    /// Select all, then delete. Always, because an empty field reads as its placeholder,
    /// so what a field shows can't say whether it's empty.
    private func clear(on input: any Input) -> Bool {
        guard let selectAll = KeyboardKey.from(wireCode: "KeyA"), let delete = KeyboardKey.from(wireCode: "Backspace")
        else { return false }
        return selectAll.press(modifiers: [.command], duration: TypeText.keyHold, on: input)
            && delete.press(duration: TypeText.keyHold, on: input)
    }
}

/// How a fill ended.
enum FillOutcome: Equatable, Sendable {
    /// The field shows the text, or the same letters and digits with other punctuation.
    case filled(name: String, shows: String)
    /// Asked for no text. There's nothing to read back: an empty field reads as its placeholder.
    case cleared(name: String)
    /// Still not the text after the retry. `wanted` is safe to repeat: a password is only its length.
    case differs(name: String, shows: String, wanted: String)
    case notATextField(name: String)
    case neverFocused(name: String)
    /// Device Hub holds the simulator's input, so nothing can land until it's healed.
    case inputTaken(name: String)
    case unreachable(AXTarget.Refusal)
    case failed(String)

    /// `true` means the field shows the text, not that keys were sent.
    var isOK: Bool {
        switch self {
        case .filled, .cleared: return true
        default: return false
        }
    }

    /// A miss Device Hub could explain: the field was found, and nothing landed in it.
    fileprivate var mayBeInputTaken: Bool {
        switch self {
        case .differs, .neverFocused: return true
        default: return false
        }
    }

    fileprivate var fieldName: String? {
        switch self {
        case .differs(let name, _, _), .neverFocused(let name): return name
        default: return nil
        }
    }

    /// The fields of the answer, for the App to serialize.
    var answer: [String: Any] {
        switch self {
        case .filled(let name, let shows):
            return ["ok": true, "filled": name, "value": shows]
        case .cleared(let name):
            return ["ok": true, "filled": name, "value": ""]
        case .differs(let name, let shows, let wanted):
            return ["ok": false, "error": "\(name) shows \"\(shows)\", not \(wanted)", "value": shows]
        case .notATextField(let name):
            return ["ok": false, "error": "\(name) isn't a text field, so nothing was typed"]
        case .neverFocused(let name):
            return ["ok": false, "error": "\(name) never took focus, so nothing was typed"]
        case .inputTaken(let name):
            return [
                "ok": false,
                "error": "Device Hub has taken this simulator's input, so nothing reached \(name). "
                    + "Run baguette heal, which restarts SpringBoard and ends running apps.",
            ]
        case .unreachable(let refusal):
            var answer: [String: Any] = ["ok": false, "error": refusal.message]
            refusal.details.forEach { answer[$0.key] = $0.value }
            return answer
        case .failed(let message):
            return ["ok": false, "error": message]
        }
    }
}
