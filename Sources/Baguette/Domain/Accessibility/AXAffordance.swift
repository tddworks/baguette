import Foundation

/// An affordance is what an agent can do next on this screen, so it needs nothing
/// beyond the answer: each verb says the command to run and what it takes. One command
/// per verb, not per control, because a screen can have 120 controls and an agent pays
/// for every token. Baguette presses a control through accessibility, by name, so where a
/// control is doesn't matter: only whether it's enabled, which iOS reports directly.
enum AXAffordance {
    /// How a next step is spelled: as a command for a one-shot caller, or as an
    /// envelope for a `baguette input` session.
    enum Style: Equatable, Sendable {
        case commandLine(program: String, udid: String, deviceSet: String?)
        case wire
    }

    /// One thing that can be done next. It says what it is once, and each caller gets
    /// it in its own spelling. The name is `name` for a form that takes any of several.
    enum Action: Equatable, Sendable {
        static let name = "<name>"

        case tap(String)
        case fill(String)
        case type(String)
        /// A slider: a press can't set a value, so a drag starts from where it is now.
        case drag(String, from: Point, size: Size)
        case heal

        var verb: String {
            switch self {
            case .tap: return Tap.wireType
            case .fill: return Fill.wireType
            case .type: return TypeText.wireType
            case .drag: return Swipe.wireType
            case .heal: return "heal"
            }
        }

        func spelled(_ style: Style) -> Any {
            switch style {
            case .commandLine(let program, _, _): return command(program, style)
            case .wire: return envelope
            }
        }

        private func command(_ program: String, _ style: Style) -> String {
            let device = AXAffordance.device(style)
            switch self {
            case .tap(let name):
                return "\(program) tap \(device) --label \(Self.quoted(name)) --then-describe-ui"
            case .fill(let name):
                return "\(program) fill \(device) --label \(Self.quoted(name)) --text <text>"
            case .type:
                return "\(program) type \(device) --text <text>"
            case .drag(_, let from, let size):
                let (x, y) = (Int(from.x.rounded()), Int(from.y.rounded()))
                return "\(program) swipe \(device) --start-x \(x) --start-y \(y) --end-x <x> --end-y \(y)"
                    + " --width \(Int(size.width.rounded())) --height \(Int(size.height.rounded())) --then-describe-ui"
            case .heal:
                return "\(program) heal \(device)"
            }
        }

        private var envelope: Any {
            switch self {
            case .tap(let name):
                return ["type": Tap.wireType, "label": name, "then_describe_ui": true] as [String: Any]
            case .fill(let name):
                return ["type": Fill.wireType, "label": name, "text": "<text>"]
            case .type:
                return ["type": TypeText.wireType, "text": "<text>"]
            case .drag(_, let from, let size):
                return [
                    "type": Swipe.wireType, "startX": from.x, "startY": from.y, "endX": "<x>", "endY": from.y,
                    "width": size.width, "height": size.height, "then_describe_ui": true,
                ] as [String: Any]
            case .heal:
                // Not a gesture: a session can't heal itself, so it stays a command.
                return "baguette heal --udid <udid>"
            }
        }

        /// Single quotes keep a name like `Pay $1,240` from being expanded by the shell.
        private static func quoted(_ name: String) -> String {
            let plain = name.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || "_-.@".unicodeScalars.contains($0)
            }
            return plain && !name.isEmpty ? name : "'" + name.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        }
    }

    /// A rendered value as JSON: a command string or a wire envelope.
    static func json(_ rendered: Any) -> String {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        let data = (try? JSONSerialization.data(withJSONObject: rendered, options: options)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    fileprivate static func device(_ style: Style) -> String {
        guard case .commandLine(_, let udid, let deviceSet) = style else { return "" }
        return "--udid \(udid)" + (deviceSet.map { #" --device-set "\#($0)""# } ?? "")
    }
}



extension AXNode {
    /// Roles that respond to a tap by definition. Text and images can too, but
    /// nothing in the tree says so; they appear under `text`, and `--label` reaches them.
    static let controlRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSecureTextField",
        "AXCheckBox", "AXRadioButton", "AXSwitch", "AXSlider", "AXStepper",
        "AXPopUpButton", "AXMenuItem", "AXMenuButton", "AXDisclosureTriangle",
    ]

    /// The status bar's reach, which isn't what the screen says.
    private static let statusBarTop = 50.0
    private static let statusBarBottom = 64.0

    /// What an agent needs after each step: what it can do, what it can't yet, and
    /// what the screen says. Small on purpose: agents filter a long answer to read
    /// it, and lose whatever the filter drops. The whole tree is one `describe-ui`
    /// away.
    func agentSummary(_ style: AXAffordance.Style) -> [String: Any] {
        var summary = offers(style)
        var text: [String] = []
        var values: [String: String] = [:]
        for node in preorder() where node.hasSize && !node.hidden {
            guard node.isVisible(on: screen) else { continue }
            if Self.controlRoles.contains(node.role) {
                if let value = node.value, !value.isEmpty { values[node.offerName] = value }
            } else if node.role != "AXApplication", node.role != "AXGroup", let label = node.spokenLabel,
                !node.isInStatusBar, !text.contains(label)
            {
                text.append(label)
            }
        }
        if !text.isEmpty { summary["text"] = text }
        if !values.isEmpty { summary["values"] = values }
        return summary
    }

    /// The summary's fields as JSON, to sit beside a gesture's own.
    func agentSummaryFields(_ style: AXAffordance.Style) -> String {
        String(AXAffordance.json(agentSummary(style)).dropFirst().dropLast())
    }

    /// What can be done and what can't yet, without the text: the tree beside it
    /// already says that.
    func offersFields(_ style: AXAffordance.Style) -> String {
        String(AXAffordance.json(offers(style)).dropFirst().dropLast())
    }

    private func offers(_ style: AXAffordance.Style) -> [String: Any] {
        let controls = preorder().filter { !$0.hidden && $0.hasSize && Self.controlRoles.contains($0.role) }
        let enabled = controls.filter(\.enabled)
        var result: [String: Any] = [
            "affordances": affordances(enabled, style)
        ]
        let disabled = numberedNames(controls.filter { !$0.enabled })
        if !disabled.isEmpty { result["disabled"] = disabled }
        return result
    }

    /// Each verb with its command and what it takes. Names sort as a person would, seat 2 before seat 10, so a caller can
    /// find one, and `command` sorts ahead of `names`, so an answer cut short keeps it.
    /// Named together, because a name reaches one control whichever verb it's under.
    private func affordances(_ enabled: [AXNode], _ style: AXAffordance.Style) -> [String: Any] {
        let pressable = enabled.filter { $0.role != "AXSlider" }
        let named = Array(zip(pressable, numberedNames(pressable)))
        var map: [String: Any] = [:]
        func offer(_ action: AXAffordance.Action, _ names: [String]) {
            guard !names.isEmpty else { return }
            map[action.verb] = ["command": action.spelled(style), "names": names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }]
        }
        let form = AXAffordance.Action.name
        offer(.tap(form), named.filter { $0.0.textField == nil }.map(\.1))
        offer(.fill(form), named.filter { $0.0.textField != nil }.map(\.1))
        offer(.type(form), enabled.filter { $0.textField?.isFocused == true }.map(\.offerName))
        // Each slider's drag starts from its own value, so each has its own command.
        if let screen {
            let sliders = enabled.filter { $0.role == "AXSlider" }
            for (node, name) in zip(sliders, numberedNames(sliders)) {
                let drag = AXAffordance.Action.drag(
                    name, from: node.thumb, size: Size(width: screen.width, height: screen.height))
                map["\(drag.verb) \(name)"] = drag.spelled(style)
            }
        }
        return map
    }

    /// Where a slider's thumb is, going by its value: `50%` or `0.5`, else its middle.
    private var thumb: Point {
        let text = (value ?? "").trimmingCharacters(in: .whitespaces)
        let fraction = text.hasSuffix("%") ? Double(text.dropLast()).map { $0 / 100 } : Double(text)
        let along = fraction.flatMap { (0...1).contains($0) ? $0 : nil } ?? 0.5
        return Point(x: frame.origin.x + frame.size.width * along, y: frame.origin.y + frame.size.height / 2)
    }

    /// Each control's name, numbered when several share it, so every name in the
    /// list reaches exactly one control.
    private func numberedNames(_ nodes: [AXNode]) -> [String] {
        let counts = Dictionary(nodes.map { ($0.offerName, 1) }, uniquingKeysWith: +)
        var seen: [String: Int] = [:]
        return nodes.map { node in
            let name = node.offerName
            guard counts[name, default: 0] > 1 else { return name }
            seen[name, default: 0] += 1
            return "\(name) #\(seen[name]!)"
        }
    }

    /// What to tell a caller whose tap at `point` changed nothing: what's there, and
    /// how to reach it by name, which doesn't depend on a point. A suggestion, never
    /// a retry: the app may have acted without changing its tree.
    func missedTap(at point: Point, style: AXAffordance.Style) -> (hint: String, next: Any?)? {
        guard let screen else { return nil }
        let place = "(\(Int(point.x.rounded())), \(Int(point.y.rounded())))"
        let hit = preorder().last {
            !$0.hidden && $0.enabled && Self.controlRoles.contains($0.role) && $0.isVisible(on: screen)
                && $0.frame.holds(point)
        }
        guard let control = hit else {
            return ("Nothing changed: there's no control at \(place). Choose from affordances.", nil)
        }
        let name = control.offerName
        return (
            "Nothing changed: \(place) is on \"\(name)\", but that spot may be blank. Try it by name.",
            AXAffordance.Action.tap(name).spelled(style)
        )
    }

    /// Where a real finger would touch: the centre of what's on screen, or `nil`
    /// when none of it is.
    func touchPoint(on screen: AXScreen) -> Point? {
        guard let visible = visibleFrame(on: screen) else { return nil }
        return Point(x: visible.origin.x + visible.size.width / 2, y: visible.origin.y + visible.size.height / 2)
    }

    func isVisible(on screen: AXScreen?) -> Bool {
        guard let screen else { return true }
        return visibleFrame(on: screen) != nil
    }

    func preorder() -> [AXNode] {
        [self] + children.flatMap { $0.preorder() }
    }

    var hasSize: Bool { frame.size.width > 0 && frame.size.height > 0 }

    /// What this element is listed as, and can be reached by.
    var offerName: String {
        if let spokenLabel { return spokenLabel }
        if let identifier, !identifier.isEmpty { return identifier }
        return String(role.trimmingPrefix("AX"))
    }

    private func visibleFrame(on screen: AXScreen) -> Rect? {
        guard hasSize else { return nil }
        let minX = max(frame.origin.x, 0)
        let minY = max(frame.origin.y, 0)
        let maxX = min(frame.origin.x + frame.size.width, screen.width)
        let maxY = min(frame.origin.y + frame.size.height, screen.height)
        guard maxX > minX, maxY > minY else { return nil }
        return Rect(origin: Point(x: minX, y: minY), size: Size(width: maxX - minX, height: maxY - minY))
    }

    /// Nothing of the app is here yet: an app the guest client just woke reads like
    /// this until its tree appears.
    var showsOnlyTheStatusBar: Bool {
        children.allSatisfy(\.isInStatusBar)
    }

    private var isInStatusBar: Bool {
        frame.origin.y < Self.statusBarTop && frame.origin.y + frame.size.height <= Self.statusBarBottom
    }

    private var spokenLabel: String? {
        let flat = (label ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.isEmpty ? nil : flat
    }
}

extension Rect {
    fileprivate func holds(_ point: Point) -> Bool {
        point.x >= origin.x && point.x < origin.x + size.width
            && point.y >= origin.y && point.y < origin.y + size.height
    }
}

extension AXNode {
    /// How far a nameless element can move and still be taken for the same one.
    private static let sameSpot = 30.0
    /// Movement this small is a pulse or a glow, not a change of screen. A scroll
    /// or a page sliding moves much further.
    private static let pulse = 4.0

    /// Which of `candidates` is this element, read a moment ago. A control can have
    /// moved a little since, so identity is what it's called, and position only
    /// separates several with the same name. A nameless element has only its
    /// position to go on, so it must still be close.
    func bestMatch(among candidates: [AXNode]) -> AXNode? {
        let same = candidates.filter { $0.role == role && $0.label == label && $0.identifier == identifier }
        guard let nearest = same.min(by: { distance(to: $0) < distance(to: $1) }) else { return nil }
        if label == nil, identifier == nil, distance(to: nearest) > Self.sameSpot { return nil }
        return nearest
    }

    /// Whether two reads show the same screen, allowing for a pulse. What it says
    /// and how it's built must match exactly.
    func looksSame(as other: AXNode) -> Bool {
        guard role == other.role, label == other.label, value == other.value, identifier == other.identifier,
            enabled == other.enabled, hidden == other.hidden, focused == other.focused,
            children.count == other.children.count, distance(to: other) <= Self.pulse
        else { return false }
        return zip(children, other.children).allSatisfy { $0.looksSame(as: $1) }
    }

    private func distance(to other: AXNode) -> Double {
        max(abs(frame.origin.x - other.frame.origin.x), abs(frame.origin.y - other.frame.origin.y))
    }
}
