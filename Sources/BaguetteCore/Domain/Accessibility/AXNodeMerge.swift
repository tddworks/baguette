import Foundation

/// Hit-test discovery merge for `AXNode`.
///
/// The recursive `accessibilityChildren` walk is *process-scoped* and
/// can't descend into childless SwiftUI containers, so two kinds of
/// element go missing: SpringBoard's status bar (a different process)
/// and the contents of containers that report empty children but
/// still answer positional hit-tests (tab bars, nav bars, toolbars).
/// The adapter recovers them with an `objectAtPoint` grid sweep; this
/// extension decides *which screen regions the sweep may skip* and
/// *where each discovery belongs in the tree*.
extension AXNode {

    /// Roles that fully describe themselves as a single element. A
    /// childless node with one of these roles is a genuine leaf — the
    /// grid sweep can skip its interior. Everything else (groups,
    /// scroll areas, toolbars, unknowns) is treated as a *container*:
    /// even when the recursive walk reports it childless it may hide
    /// hit-testable children, so the sweep must keep probing inside it.
    static let contentLeafRoles: Set<String> = [
        "AXStaticText", "AXButton", "AXImage", "AXTextField", "AXTextArea",
        "AXSecureTextField", "AXLink", "AXCheckBox", "AXRadioButton",
        "AXSlider", "AXSwitch", "AXStepper", "AXValueIndicator",
        "AXPopUpButton", "AXMenuItem", "AXMenuButton",
        "AXDisclosureTriangle", "AXProgressIndicator",
    ]

    /// A childless node whose role marks it as self-describing.
    var isContentLeaf: Bool {
        children.isEmpty && Self.contentLeafRoles.contains(role)
    }

    /// Centre of this node's frame — used to decide which container a
    /// discovered element falls inside.
    var center: Point {
        Point(x: frame.origin.x + frame.size.width / 2,
              y: frame.origin.y + frame.size.height / 2)
    }

    /// Frames the grid sweep may skip — *only* genuine content leaves,
    /// never childless containers (whose interior may hold tab-bar /
    /// nav-bar items the recursive walk couldn't reach). This is the
    /// leaf-vs-container distinction that keeps the sweep both cheap
    /// (real leaves aren't re-probed) and complete (containers stay
    /// probeable).
    func contentLeafFrames() -> [Rect] {
        var out: [Rect] = []
        collectContentLeaves(into: &out)
        return out
    }

    private func collectContentLeaves(into out: inout [Rect]) {
        if isContentLeaf { out.append(frame); return }
        for child in children { child.collectContentLeaves(into: &out) }
    }

    /// Stable de-duplication identity: role + identifier + label +
    /// rounded frame. The sweep yields a *fresh* translation object
    /// per point (object identity is useless) and re-hits one element
    /// from several adjacent samples — this key recognises "same
    /// element" across both.
    var dedupKey: String {
        let x = frame.origin.x.rounded()
        let y = frame.origin.y.rounded()
        let w = frame.size.width.rounded()
        let h = frame.size.height.rounded()
        return "\(role)|\(identifier ?? "")|\(label ?? "")|\(x),\(y),\(w),\(h)"
    }

    /// Graft hit-test discoveries the recursive walk couldn't reach
    /// into this tree. Each node in `discovered` whose `dedupKey` is
    /// not already present — in this tree *or* earlier in `discovered`
    /// — is inserted under the **deepest existing node that contains
    /// its centre**. Grafting under the container (rather than at the
    /// root) is what makes a discovered tab-bar button selectable: a
    /// client-side hit-test descends into the `AXGroup "Tab Bar"` and
    /// finds the button, instead of stopping at the group that used to
    /// shadow it. Returns `self` unchanged when nothing is new.
    func merging(discovered: [AXNode]) -> AXNode {
        var seen = Set<String>()
        collectKeys(into: &seen)
        var fresh: [AXNode] = []
        for node in discovered where !seen.contains(node.dedupKey) {
            seen.insert(node.dedupKey)
            fresh.append(node)
        }
        guard !fresh.isEmpty else { return self }
        // Graft all fresh nodes: each lands under the deepest container
        // that contains it, and anything no container claims — e.g. the
        // status bar, which sits above the frontmost app's root frame —
        // is appended to the root.
        return graft(fresh)
    }

    /// Distribute `fresh` (all known to fall within `self.frame`) down
    /// to the children that contain them; whatever no child claims is
    /// appended to `self`. Recurses so each discovery lands at the
    /// deepest container.
    private func graft(_ fresh: [AXNode]) -> AXNode {
        var unclaimed = fresh
        let newChildren = children.map { child -> AXNode in
            let claimed = unclaimed.filter { child.contains($0.center) }
            if !claimed.isEmpty {
                unclaimed.removeAll { child.contains($0.center) }
                return child.graft(claimed)
            }
            return child
        }
        return withChildren(newChildren + unclaimed)
    }

    private func collectKeys(into set: inout Set<String>) {
        set.insert(dedupKey)
        for child in children { child.collectKeys(into: &set) }
    }

    private func contains(_ p: Point) -> Bool {
        let minX = frame.origin.x, minY = frame.origin.y
        let maxX = minX + frame.size.width, maxY = minY + frame.size.height
        return p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
    }

    private func withChildren(_ newChildren: [AXNode]) -> AXNode {
        AXNode(
            role: role, subrole: subrole, label: label, value: value,
            identifier: identifier, title: title, help: help, frame: frame,
            enabled: enabled, focused: focused, hidden: hidden,
            children: newChildren
        )
    }
}
