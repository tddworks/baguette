import Foundation

/// Native panel points and the interface rotation observed for an AX result.
public struct AXScreen: Equatable, Sendable {
    public let width: Double
    public let height: Double
    public let orientation: DeviceOrientation
    public var target: ScreenTarget? = nil

    public var dictionary: [String: Any] {
        var value: [String: Any] = ["width": width, "height": height, "orientation": orientation.wireName]
        if let target { value["target"] = target.dictionary }
        return value
    }

    public init(width: Double, height: Double, orientation: DeviceOrientation, target: ScreenTarget? = nil) {
        self.width = width
        self.height = height
        self.orientation = orientation
        self.target = target
    }
}

/// One node in the simulator's on-screen UI tree. Mirrors the shape
/// `AXPTranslator` exposes for a single `AXPMacPlatformElement` —
/// role / label / value / frame plus traits — without leaking the
/// private-API type at the domain boundary.
///
/// `frame` is in **native panel points**, the same unit as gesture wire
/// coordinates (`x`, `y`, `width`, `height`). A caller can read
/// `node.frame.origin` + half its `size` and feed it back into a
/// `tap` envelope without unit conversion.
///
/// Optional string fields are `nil` when the underlying element
/// returned an empty / absent value, so the JSON projection can
/// distinguish "not set" from "explicitly empty".
public struct AXNode: Equatable, Sendable {
    public let role: String
    public let subrole: String?
    public let label: String?
    public let value: String?
    public let identifier: String?
    public let title: String?
    public let help: String?
    public let frame: Rect
    public let enabled: Bool
    public let focused: Bool
    public let hidden: Bool
    /// The steps the element offers — `AXIncrement`, `AXDecrement` — for a
    /// slider, stepper or picker. Empty for everything else.
    public let adjustmentActions: [String]
    public let children: [AXNode]
    public var screen: AXScreen?

    public init(
        role: String,
        subrole: String? = nil,
        label: String? = nil,
        value: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        help: String? = nil,
        frame: Rect,
        enabled: Bool = true,
        focused: Bool = false,
        hidden: Bool = false,
        adjustmentActions: [String] = [],
        children: [AXNode] = [],
        screen: AXScreen? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.label = label
        self.value = value
        self.identifier = identifier
        self.title = title
        self.help = help
        self.frame = frame
        self.enabled = enabled
        self.focused = focused
        self.hidden = hidden
        self.adjustmentActions = adjustmentActions
        self.children = children
        self.screen = screen
    }

    /// JSON projection used by the `describe-ui` CLI and the WS
    /// `describe_ui_result` envelope. Sorted keys keep diffs and
    /// snapshot tests stable. Optional strings serialise as `null`
    /// (rather than being omitted) so consumers can rely on a
    /// stable schema.
    public var json: String {
        let data = try! JSONSerialization.data(
            withJSONObject: dictionary, options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// Recursive walk: deepest descendant whose `frame` contains
    /// `point` wins, or `self` when `point` is inside `self.frame`
    /// but no child claims it. AX containers do not clip descendants;
    /// their frame may be empty or smaller than a child's. Frames are half-open
    /// rectangles (`[origin, origin + size)`), matching the
    /// convention CGRect uses.
    public func hitTest(_ point: Point) -> AXNode? {
        for child in children {
            if let hit = child.hitTest(point) { return hit }
        }
        return contains(point) ? self : nil
    }

    private func contains(_ p: Point) -> Bool {
        let minX = frame.origin.x
        let minY = frame.origin.y
        let maxX = minX + frame.size.width
        let maxY = minY + frame.size.height
        return p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
    }

    /// Build an `AXNode` tree from a root `AXPMacPlatformElement`-
    /// shaped `NSObject`. Reads the standard accessibility-*
    /// properties via KVC, the CGRect-returning
    /// `accessibilityFrame` selector via a typed IMP cast, and
    /// recurses through `accessibilityChildren`. Pure logic — no
    /// CoreSimulator, no AXPTranslator, no XPC. The Infrastructure
    /// adapter (`AXPTranslatorAccessibility`) does the irreducible
    /// `dlopen` + `frontmostApplication` dance and hands the
    /// resulting root element here.
    ///
    /// `transform` rotates each node's UIKit screen frame into
    /// device-point space (`AXFrameTransform`).
    /// `depthCap` is a defensive bound (real iOS screens rarely
    /// exceed 20–30 levels; the cap prevents pathological cycles
    /// from spinning forever). `deadline` short-circuits child
    /// traversal once the wall clock passes — used by the
    /// orchestrator to honour an XPC-call deadline without
    /// abandoning the partial tree we already have.
    public static func walk(
        from element: NSObject,
        transform: AXFrameTransform,
        depthCap: Int = 60,
        deadline: Date = .distantFuture
    ) -> AXNode {
        walkInternal(
            element: element,
            depth: 0,
            transform: transform,
            depthCap: depthCap,
            deadline: deadline
        )
    }

    private static func walkInternal(
        element: NSObject,
        depth: Int,
        transform: AXFrameTransform,
        depthCap: Int,
        deadline: Date
    ) -> AXNode {
        let role = AXElementReader.string(element, "accessibilityRole") ?? "AXUnknown"
        let macFrame = AXElementReader.frame(of: element)
        let projected = transform.map(macFrame)

        let children: [AXNode]
        if depth >= depthCap || Date() >= deadline {
            children = []
        } else {
            let kids = AXElementReader.children(of: element)
            children = kids.map {
                walkInternal(
                    element: $0,
                    depth: depth + 1,
                    transform: transform,
                    depthCap: depthCap,
                    deadline: deadline
                )
            }
        }

        return AXNode(
            role: role,
            subrole: AXElementReader.string(element, "accessibilitySubrole"),
            label: AXElementReader.string(element, "accessibilityLabel"),
            value: AXElementReader.stringOrNumber(element, "accessibilityValue"),
            identifier: AXElementReader.string(element, "accessibilityIdentifier"),
            title: AXElementReader.string(element, "accessibilityTitle"),
            help: AXElementReader.string(element, "accessibilityHelp"),
            frame: Rect(
                origin: Point(x: Double(projected.origin.x), y: Double(projected.origin.y)),
                size: Size(width: Double(projected.size.width), height: Double(projected.size.height))
            ),
            enabled: AXElementReader.bool(element, "accessibilityEnabled", default: true)
                || AXElementReader.bool(element, "isAccessibilityEnabled", default: false),
            focused: AXElementReader.bool(element, "isAccessibilityFocused", default: false)
                || AXElementReader.bool(element, "accessibilityFocused", default: false),
            hidden: AXElementReader.bool(element, "isAccessibilityHidden", default: false)
                || AXElementReader.bool(element, "accessibilityHidden", default: false),
            adjustmentActions: AXElementReader.adjustmentActions(element),
            children: children
        )
    }

    /// The same projection with what can be done added at the top, so it's the
    /// first thing a reader sees. The tree's own fields stay as they are.
    public func json(affordances style: AXAffordance.Style) -> String {
        "{" + offersFields(style) + "," + String(json.dropFirst())
    }

    fileprivate var dictionary: [String: Any] {
        var result: [String: Any] = [
            "role": role,
            "subrole": subrole as Any? ?? NSNull(),
            "label": label as Any? ?? NSNull(),
            "value": value as Any? ?? NSNull(),
            "identifier": identifier as Any? ?? NSNull(),
            "title": title as Any? ?? NSNull(),
            "help": help as Any? ?? NSNull(),
            "frame": [
                "x": frame.origin.x,
                "y": frame.origin.y,
                "width": frame.size.width,
                "height": frame.size.height,
            ],
            "enabled": enabled,
            "focused": focused,
            "hidden": hidden,
            "children": children.map(\.dictionary),
        ]
        if let screen {
            result["screen"] = screen.dictionary
        }
        // Only where there is something to step: a screen holds many
        // controls and few sliders, and every field costs a reader tokens.
        if !adjustmentActions.isEmpty {
            result["adjustable"] = true
            result["adjustmentActions"] = adjustmentActions
        }
        return result
    }
}

public extension AXNode {
    /// The tree with its screen taken from the app at its root, which fills
    /// the screen — for a device that reports no screen of its own (a
    /// physical phone). Portrait: its frames are in the app's own points.
    var onItsAppsScreen: AXNode {
        guard screen == nil else { return self }
        var tree = self
        tree.screen = AXScreen(width: frame.size.width, height: frame.size.height, orientation: .portrait)
        return tree
    }
}
