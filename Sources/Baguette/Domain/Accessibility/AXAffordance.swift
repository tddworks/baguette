import Foundation

/// An affordance is what an agent can do on this screen right now, so everything
/// here depends on the screen. What's always true, like the device's UDID or how to
/// go home, isn't an affordance and isn't repeated. Baguette presses a control
/// through accessibility, by name, so where a control is doesn't matter: only
/// whether it's enabled, which iOS reports directly.
enum AXAffordance {
    /// How a next step is spelled: as a command for a one-shot caller, or as an
    /// envelope for a `baguette input` session.
    enum Style: Equatable, Sendable {
        case commandLine(program: String, udid: String, deviceSet: String?)
        case wire
    }

    /// How to act, for a caller that hasn't yet. An answer to a tap leaves it out,
    /// because the caller just ran it.
    static func how(_ style: Style, screen: AXScreen?) -> [String: Any] {
        var how: [String: Any] = [
            "tap": tapByName("<name>", style),
            "adjust": "A press can't set a value. Drag a slider with swipe: describe-ui has its frame.",
        ]
        if case .commandLine(let program, _, _) = style {
            let size = screen.map { " --width \(Int($0.width.rounded())) --height \(Int($0.height.rounded()))" } ?? ""
            how["swipe"] = "\(program) swipe \(device(style)) --start-x <x> --start-y <y> --end-x <x> --end-y <y>\(size) --then-describe-ui"
        }
        return how
    }

    /// A tap on one element by name. Single quotes keep a name like `Pay $1,240`
    /// from being expanded by the shell.
    static func tapByName(_ name: String, _ style: Style) -> Any {
        switch style {
        case .commandLine(let program, _, _):
            let quoted = name.replacingOccurrences(of: "'", with: #"'\''"#)
            return "\(program) tap \(device(style)) --label '\(quoted)' --then-describe-ui"
        case .wire:
            return ["type": Tap.wireType, "label": name, "then_describe_ui": true] as [String: Any]
        }
    }

    /// A rendered value as JSON: a command string or a wire envelope.
    static func json(_ rendered: Any) -> String {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        let data = (try? JSONSerialization.data(withJSONObject: rendered, options: options)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func device(_ style: Style) -> String {
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
    func agentSummary(_ style: AXAffordance.Style, withHow: Bool = false) -> [String: Any] {
        var summary = offers(style, withHow: withHow)
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
    func agentSummaryFields(_ style: AXAffordance.Style, withHow: Bool = false) -> String {
        String(AXAffordance.json(agentSummary(style, withHow: withHow)).dropFirst().dropLast())
    }

    /// What can be done and what can't yet, without the text: the tree beside it
    /// already says that.
    func offersFields(_ style: AXAffordance.Style) -> String {
        String(AXAffordance.json(offers(style, withHow: true)).dropFirst().dropLast())
    }

    private func offers(_ style: AXAffordance.Style, withHow: Bool) -> [String: Any] {
        let controls = preorder().filter { !$0.hidden && $0.hasSize && Self.controlRoles.contains($0.role) }
        let enabled = controls.filter(\.enabled)
        var affordances: [String: Any] = [:]
        let names = numberedNames(enabled.filter { $0.role != "AXSlider" })
        if !names.isEmpty { affordances["tap"] = names }
        let sliders = numberedNames(enabled.filter { $0.role == "AXSlider" })
        if !sliders.isEmpty { affordances["adjust"] = sliders }
        let typeable = enabled.filter { $0.textField?.isFocused == true }.map(\.offerName)
        if !typeable.isEmpty { affordances["type"] = typeable }

        var result: [String: Any] = ["affordances": affordances]
        let disabled = numberedNames(controls.filter { !$0.enabled })
        if !disabled.isEmpty { result["disabled"] = disabled }
        if withHow { result["how"] = AXAffordance.how(style, screen: screen) }
        return result
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
            AXAffordance.tapByName(name, style)
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
