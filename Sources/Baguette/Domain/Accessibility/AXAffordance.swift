import Foundation

/// A next step on this screen, ready to run. `describe-ui` has already
/// found everything, so it can hand over the finished command, and no second
/// read is needed to act on it. State-aware: an element offers only what will
/// work right now, so a disabled button or an off-screen row offers no tap.
///
/// They're gathered in one map at the top of the output, because an agent
/// filters a long tree to read it, and offers on the elements get filtered away.
///
/// One value renders two ways, because a one-shot CLI caller and a
/// `baguette input` session act through different surfaces.
enum AXAffordance: Equatable {
    case tap(Point, Size)
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
    /// nothing in the tree says so, and offering a tap on every heading would
    /// claim they all respond.
    private static let controlRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSecureTextField",
        "AXCheckBox", "AXRadioButton", "AXSwitch", "AXSlider", "AXStepper",
        "AXPopUpButton", "AXMenuItem", "AXMenuButton", "AXDisclosureTriangle",
    ]
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSecureTextField"]

    /// How far in from a wide row's left edge its label sits.
    private static let leadingInset = 40.0
    /// Narrower than this, an element's centre is on what it draws.
    private static let wideRow = 200.0

    /// Every next step under this node, keyed by what it does, like
    /// `tap Search flights`. Controls that share a name are numbered.
    func affordanceMap(_ style: AXAffordance.Style) -> [String: Any] {
        var map: [String: Any] = [:]
        if let home = AXAffordance.home.rendered(style) { map["home"] = home }
        if let shot = AXAffordance.screenshot.rendered(style) { map["screenshot"] = shot }
        var uses: [String: Int] = [:]
        func add(_ verb: String, _ name: String, _ offer: AXAffordance) {
            guard let rendered = offer.rendered(style) else { return }
            let key = "\(verb) \(name)"
            uses[key, default: 0] += 1
            map[uses[key] == 1 ? key : "\(key) #\(uses[key]!)"] = rendered
        }
        func walk(_ node: AXNode) {
            if let screen, !node.hidden, node.enabled, Self.controlRoles.contains(node.role),
                let visible = node.visibleFrame(on: screen)
            {
                let name = node.offerName
                add("tap", name, .tap(node.tapPoint(in: visible), Size(width: screen.width, height: screen.height)))
                if node.focused, Self.textRoles.contains(node.role) { add("type", name, .type) }
            }
            node.children.forEach(walk)
        }
        walk(self)
        return map
    }

    /// The map on its own, for an answer that carries it beside the tree.
    func affordancesJSON(_ style: AXAffordance.Style) -> String {
        AXAffordance.json(affordanceMap(style))
    }

    /// What to tell a caller whose tap at `point` changed nothing: what's there,
    /// and the point baguette would use if that's a different one. A hit-test
    /// can't say the app will respond, so this suggests, and never retries: the
    /// app may have acted without changing its tree.
    func missedTap(at point: Point, style: AXAffordance.Style) -> (hint: String, next: Any?)? {
        guard let screen else { return nil }
        let where_ = "(\(Int(point.x.rounded())), \(Int(point.y.rounded())))"
        guard let control = controlAt(point, on: screen), let visible = control.visibleFrame(on: screen) else {
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

    private func controlAt(_ point: Point, on screen: AXScreen) -> AXNode? {
        var found: AXNode?
        func walk(_ node: AXNode) {
            if !node.hidden, node.enabled, Self.controlRoles.contains(node.role),
                let visible = node.visibleFrame(on: screen),
                point.x >= visible.origin.x, point.x < visible.origin.x + visible.size.width,
                point.y >= visible.origin.y, point.y < visible.origin.y + visible.size.height
            {
                found = node
            }
            node.children.forEach(walk)
        }
        walk(self)
        return found
    }

    private var offerName: String {
        let label = (label ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if !label.isEmpty { return label }
        if let identifier, !identifier.isEmpty { return identifier }
        return String(role.trimmingPrefix("AX"))
    }

    /// The centre of what's on screen, or near the left of a wide row whose
    /// label has several parts: a name on the left and a price on the right
    /// leave its centre blank, and the app ignores a tap there.
    private func tapPoint(in visible: Rect) -> Point {
        let y = visible.origin.y + visible.size.height / 2
        if (label ?? "").contains(", "), visible.size.width >= Self.wideRow {
            return Point(x: visible.origin.x + Self.leadingInset, y: y)
        }
        return Point(x: visible.origin.x + visible.size.width / 2, y: y)
    }

    private func visibleFrame(on screen: AXScreen) -> Rect? {
        let minX = max(frame.origin.x, 0)
        let minY = max(frame.origin.y, 0)
        let maxX = min(frame.origin.x + frame.size.width, screen.width)
        let maxY = min(frame.origin.y + frame.size.height, screen.height)
        guard maxX > minX, maxY > minY else { return nil }
        return Rect(origin: Point(x: minX, y: minY), size: Size(width: maxX - minX, height: maxY - minY))
    }
}
