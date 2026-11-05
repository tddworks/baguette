import Foundation

/// A next step an element offers, ready to run. `describe-ui` has already
/// found everything, so it can hand over the finished command, and no second
/// read is needed to act on it. State-aware: an element offers only what will
/// work right now, so a disabled button or an off-screen row offers no tap.
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

    var key: String {
        switch self {
        case .tap: "tap"
        case .type: "type"
        case .home: "home"
        case .screenshot: "screenshot"
        }
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

    /// What this node offers on `screen`. The root also offers what isn't
    /// about any one element.
    func affordances(on screen: AXScreen?, isRoot: Bool) -> [AXAffordance] {
        var offers: [AXAffordance] = isRoot ? [.home, .screenshot] : []
        guard let screen, !hidden, enabled, Self.controlRoles.contains(role),
            let visible = visibleFrame(on: screen)
        else { return offers }
        offers.append(.tap(tapPoint(in: visible), Size(width: screen.width, height: screen.height)))
        if focused, Self.textRoles.contains(role) { offers.append(.type) }
        return offers
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
