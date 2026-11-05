import Foundation

/// A next step on this screen, ready to run. `describe-ui` has already found
/// everything, so it can hand over what to do without a second read. State-aware:
/// a control offers a tap only when one should work right now, and the rest are
/// listed apart with the reason, so a missing button isn't a mystery.
///
/// One value renders two ways, because a one-shot CLI caller and a
/// `baguette input` session act through different surfaces.
enum AXAffordance: Equatable {
    case tap(Point, Size)
    case tapByName
    case type
    case home
    case screenshot

    enum Style: Equatable, Sendable {
        case commandLine(program: String, udid: String, deviceSet: String?)
        case wire
    }

    /// A string to run, or a wire envelope to send. `nil` when the style has
    /// no way to do it.
    func rendered(_ style: Style) -> Any? {
        switch style {
        case .commandLine(let program, let udid, let deviceSet):
            let device = "--udid \(udid)" + (deviceSet.map { #" --device-set "\#($0)""# } ?? "")
            switch self {
            case .tap(let point, let size):
                let position = "--x \(Self.whole(point.x)) --y \(Self.whole(point.y))"
                let screen = "--width \(Self.whole(size.width)) --height \(Self.whole(size.height))"
                return "\(program) tap \(device) \(position) \(screen) --then-describe-ui"
            case .tapByName: return #"\#(program) tap \#(device) --label "<name>" --then-describe-ui"#
            case .type: return #"\#(program) type \#(device) --text "<text>""#
            case .home: return "\(program) press \(device) --button home"
            case .screenshot: return "\(program) screenshot \(device) --output /tmp/baguette-screen.jpg"
            }
        case .wire:
            switch self {
            case .tap(let point, let size):
                return [
                    "type": Tap.wireType, "x": Double(Self.whole(point.x)), "y": Double(Self.whole(point.y)),
                    "width": size.width, "height": size.height, "then_describe_ui": true,
                ] as [String: Any]
            case .tapByName: return ["type": Tap.wireType, "label": "<name>", "then_describe_ui": true] as [String: Any]
            case .type: return ["type": TypeText.wireType, "text": "<text>"]
            case .home: return ["type": Press.wireType, "button": "home"]
            case .screenshot: return nil
            }
        }
    }

    private static func whole(_ value: Double) -> Int { Int(value.rounded()) }

    /// A rendered value as JSON: a command string or a wire envelope.
    static func json(_ rendered: Any) -> String {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        let data = (try? JSONSerialization.data(withJSONObject: rendered, options: options)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

extension AXNode {
    /// Roles that respond to a tap by definition. Text and images can too, but
    /// nothing in the tree says so; `--label` still reaches them.
    static let controlRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSecureTextField",
        "AXCheckBox", "AXRadioButton", "AXSwitch", "AXSlider", "AXStepper",
        "AXPopUpButton", "AXMenuItem", "AXMenuButton", "AXDisclosureTriangle",
    ]
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSecureTextField"]

    /// How far in from a wide row's left edge its label sits.
    private static let leadingInset = 40.0
    /// Narrower than this, an element's centre is on what it draws.
    private static let wideRow = 200.0
    /// The status bar's reach, which isn't what the screen says.
    private static let statusBarTop = 50.0
    private static let statusBarBottom = 64.0

    /// What an agent needs after each step: what it can do and what the screen
    /// says. Small on purpose. Agents filter a long answer to read it, and lose
    /// whatever the filter drops, so the whole tree stays one `describe-ui` away.
    func agentSummary(_ style: AXAffordance.Style) -> [String: Any] {
        var summary: [String: Any] = ["affordances": affordanceMap(style)]
        if let screen { summary["screen"] = ["width": screen.width, "height": screen.height] }
        var text: [String] = []
        var values: [String: String] = [:]
        for node in preorder() where node.frame.size.width > 0 && !node.hidden {
            let isControl = Self.controlRoles.contains(node.role)
            if isControl {
                if let value = node.value, !value.isEmpty, node.isVisible(on: screen) { values[node.offerName] = value }
            } else if node.role != "AXApplication", node.role != "AXGroup", let label = node.spokenLabel,
                node.isVisible(on: screen), !node.isInStatusBar, !text.contains(label)
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

    /// What can be done on this screen, keyed by what it does. Named controls
    /// share one command, which keeps a screen of a hundred controls small; ones
    /// no name can reach get their own coordinates.
    func affordanceMap(_ style: AXAffordance.Style) -> [String: Any] {
        var map: [String: Any] = [:]
        if let home = AXAffordance.home.rendered(style) { map["home"] = home }
        if let shot = AXAffordance.screenshot.rendered(style) { map["screenshot"] = shot }
        guard let screen else { return map }

        let nodes = preorder()
        let controls = nodes.filter { !$0.hidden && Self.controlRoles.contains($0.role) && $0.hasSize }
        let usable = controls.filter { $0.enabled && $0.isVisible(on: screen) && !isCovered($0, on: screen) }
        let counts = Dictionary(usable.map { ($0.offerName, 1) }, uniquingKeysWith: +)

        var names: [String] = []
        var numbered: [String: Int] = [:]
        for control in usable {
            let name = control.offerName
            if counts[name] == 1, control.isNameable {
                names.append(name)
            } else if let rendered = control.coordinateTap(on: screen)?.rendered(style) {
                numbered[name, default: 0] += 1
                let suffix = numbered[name] == 1 ? "" : " #\(numbered[name]!)"
                map["tap \(name)\(suffix)"] = rendered
            }
            if control.focused, Self.textRoles.contains(control.role),
                let type = AXAffordance.type.rendered(style)
            {
                map["type \(name)"] = type
            }
        }
        if !names.isEmpty {
            map["tap"] = AXAffordance.tapByName.rendered(style)
            map["tap_names"] = names
        }
        func list(_ key: String, _ nodes: [AXNode]) {
            if !nodes.isEmpty { map[key] = nodes.map(\.offerName) }
        }
        list("disabled", controls.filter { !$0.enabled && $0.isVisible(on: screen) })
        list("covered", controls.filter { $0.enabled && $0.isVisible(on: screen) && isCovered($0, on: screen) })
        list("off_screen", controls.filter { $0.enabled && !$0.isVisible(on: screen) })
        return map
    }

    /// The map on its own.
    func affordancesJSON(_ style: AXAffordance.Style) -> String {
        AXAffordance.json(affordanceMap(style))
    }

    /// Whether something drawn later sits over `node`'s tap point. A later control
    /// or a bar counts; what's inside `node` itself doesn't. The tree lists floating
    /// bars after the content they float over.
    func isCovered(_ node: AXNode, on screen: AXScreen) -> Bool {
        // A tab sits in its bar, wherever the tree happens to list the bar.
        guard node.subrole != "AXTabButton", let visible = node.visibleFrame(on: screen) else { return false }
        let point = node.tapPoint(in: visible)
        let nodes = preorder()
        guard let index = nodes.firstIndex(of: node) else { return false }
        let inside = node.preorder().count
        return nodes.dropFirst(index + inside).contains { later in
            !later.hidden && later.hasSize && later.isOccluder && later.frame.containsPoint(point)
        }
    }

    /// What to tell a caller whose tap at `point` changed nothing: what's there,
    /// and the point baguette would use if that's a different one. A hit-test
    /// can't say the app will respond, so this suggests, and never retries: the
    /// app may have acted without changing its tree.
    func missedTap(at point: Point, style: AXAffordance.Style) -> (hint: String, next: Any?)? {
        guard let screen else { return nil }
        let where_ = "(\(Int(point.x.rounded())), \(Int(point.y.rounded())))"
        let hit = preorder().last {
            !$0.hidden && $0.enabled && Self.controlRoles.contains($0.role) && $0.isVisible(on: screen)
                && $0.frame.containsPoint(point)
        }
        guard let control = hit, let visible = control.visibleFrame(on: screen) else {
            return ("Nothing changed: there's no control at \(where_). Choose from affordances.", nil)
        }
        let name = control.offerName
        let offered = control.tapPoint(in: visible)
        if offered.x.rounded() == point.x.rounded(), offered.y.rounded() == point.y.rounded() {
            return (
                "Nothing changed: \"\(name)\" may not respond here, or the app acted without changing the screen. "
                    + "Take a screenshot before tapping again.", nil)
        }
        let tap = AXAffordance.tap(offered, Size(width: screen.width, height: screen.height))
        return ("Nothing changed: \(where_) is on \"\(name)\", but that spot may be blank. Try this instead.", tap.rendered(style))
    }

    /// The centre of what's on screen, or near the left of a wide row whose
    /// label has several parts: a name on the left and a price on the right
    /// leave its centre blank, and the app ignores a tap there.
    func tapPoint(in visible: Rect) -> Point {
        let y = visible.origin.y + visible.size.height / 2
        if (label ?? "").contains(", "), visible.size.width >= Self.wideRow {
            return Point(x: visible.origin.x + Self.leadingInset, y: y)
        }
        return Point(x: visible.origin.x + visible.size.width / 2, y: y)
    }

    func visibleFrame(on screen: AXScreen) -> Rect? {
        guard hasSize else { return nil }
        let minX = max(frame.origin.x, 0)
        let minY = max(frame.origin.y, 0)
        let maxX = min(frame.origin.x + frame.size.width, screen.width)
        let maxY = min(frame.origin.y + frame.size.height, screen.height)
        guard maxX > minX, maxY > minY else { return nil }
        return Rect(origin: Point(x: minX, y: minY), size: Size(width: maxX - minX, height: maxY - minY))
    }

    func preorder() -> [AXNode] {
        [self] + children.flatMap { $0.preorder() }
    }

    private var hasSize: Bool { frame.size.width > 0 && frame.size.height > 0 }

    private func isVisible(on screen: AXScreen?) -> Bool {
        guard let screen else { return true }
        return visibleFrame(on: screen) != nil
    }

    private var isOccluder: Bool {
        Self.controlRoles.contains(role) || (role == "AXGroup" && (label ?? "").localizedCaseInsensitiveContains("bar"))
    }

    private var isInStatusBar: Bool {
        frame.origin.y < Self.statusBarTop && frame.origin.y + frame.size.height <= Self.statusBarBottom
    }

    private var spokenLabel: String? {
        let flat = (label ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.isEmpty ? nil : flat
    }

    private var isNameable: Bool { spokenLabel != nil || !(identifier ?? "").isEmpty }

    private var offerName: String {
        if let spokenLabel { return spokenLabel }
        if let identifier, !identifier.isEmpty { return identifier }
        return String(role.trimmingPrefix("AX"))
    }

    private func coordinateTap(on screen: AXScreen) -> AXAffordance? {
        visibleFrame(on: screen).map {
            .tap(tapPoint(in: $0), Size(width: screen.width, height: screen.height))
        }
    }
}

extension Rect {
    fileprivate func containsPoint(_ point: Point) -> Bool {
        point.x >= origin.x && point.x < origin.x + size.width
            && point.y >= origin.y && point.y < origin.y + size.height
    }
}
