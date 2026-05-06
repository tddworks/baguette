import Foundation

/// One node in the simulator's on-screen UI tree. Mirrors the shape
/// `AXPTranslator` exposes for a single `AXPMacPlatformElement` —
/// role / label / value / frame plus traits — without leaking the
/// private-API type at the domain boundary.
///
/// `frame` is in **device points**, the same unit as gesture wire
/// coordinates (`x`, `y`, `width`, `height`). A caller can read
/// `node.frame.origin` + half its `size` and feed it back into a
/// `tap` envelope without unit conversion.
///
/// Optional string fields are `nil` when the underlying element
/// returned an empty / absent value, so the JSON projection can
/// distinguish "not set" from "explicitly empty".
struct AXNode: Equatable, Sendable {
    let role: String
    let subrole: String?
    let label: String?
    let value: String?
    let identifier: String?
    let title: String?
    let help: String?
    let frame: Rect
    let enabled: Bool
    let focused: Bool
    let hidden: Bool
    let children: [AXNode]

    init(
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
        children: [AXNode] = []
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
        self.children = children
    }

    /// JSON projection used by the `describe-ui` CLI and the WS
    /// `describe_ui_result` envelope. Sorted keys keep diffs and
    /// snapshot tests stable. Optional strings serialise as `null`
    /// (rather than being omitted) so consumers can rely on a
    /// stable schema.
    var json: String {
        let data = try! JSONSerialization.data(
            withJSONObject: dictionary, options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// Recursive walk: deepest descendant whose `frame` contains
    /// `point` wins, or `self` when `point` is inside `self.frame`
    /// but no child claims it. Returns `nil` when `point` is
    /// outside `self.frame`. Frames are interpreted as half-open
    /// rectangles (`[origin, origin + size)`), matching the
    /// convention CGRect uses.
    func hitTest(_ point: Point) -> AXNode? {
        guard contains(point) else { return nil }
        for child in children {
            if let hit = child.hitTest(point) { return hit }
        }
        return self
    }

    private func contains(_ p: Point) -> Bool {
        let minX = frame.origin.x
        let minY = frame.origin.y
        let maxX = minX + frame.size.width
        let maxY = minY + frame.size.height
        return p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
    }

    fileprivate var dictionary: [String: Any] {
        [
            "role":       role,
            "subrole":    subrole as Any? ?? NSNull(),
            "label":      label as Any? ?? NSNull(),
            "value":      value as Any? ?? NSNull(),
            "identifier": identifier as Any? ?? NSNull(),
            "title":      title as Any? ?? NSNull(),
            "help":       help as Any? ?? NSNull(),
            "frame": [
                "x":      frame.origin.x,
                "y":      frame.origin.y,
                "width":  frame.size.width,
                "height": frame.size.height,
            ],
            "enabled":  enabled,
            "focused":  focused,
            "hidden":   hidden,
            "children": children.map(\.dictionary),
        ]
    }
}
