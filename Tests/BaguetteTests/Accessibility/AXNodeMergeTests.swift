import Testing
import Foundation
@testable import BaguetteCore

/// Hit-test merge helpers: classify which frames the grid may skip
/// (genuine content leaves, never childless containers) and graft
/// hit-test discoveries into the tree under the deepest container that
/// contains them — so a tab-bar button discovered inside an otherwise
/// childless `AXGroup "Tab Bar"` becomes selectable, not shadowed by
/// the group.
@Suite("AXNode merge")
struct AXNodeMergeTests {

    private func node(
        _ role: String, label: String? = nil, id: String? = nil,
        x: Double, y: Double, w: Double, h: Double,
        children: [AXNode] = []
    ) -> AXNode {
        AXNode(
            role: role, label: label, identifier: id,
            frame: Rect(origin: Point(x: x, y: y), size: Size(width: w, height: h)),
            children: children
        )
    }

    // MARK: - skip set

    @Test func `contentLeafFrames keeps content leaves but skips childless containers`() {
        let text = node("AXStaticText", label: "5", x: 10, y: 10, w: 40, h: 40)
        let emptyTabBar = node("AXGroup", label: "Tab Bar", x: 0, y: 900, w: 440, h: 80)
        let root = node("AXWindow", x: 0, y: 0, w: 440, h: 956,
                        children: [text, emptyTabBar])
        let frames = root.contentLeafFrames()
        #expect(frames.contains(text.frame))         // real content leaf → skippable
        #expect(!frames.contains(emptyTabBar.frame)) // childless container → must stay probeable
    }

    // MARK: - grafting

    @Test func `merging grafts a discovery under the deepest container that contains it`() {
        // A childless tab-bar container the recursive walk couldn't
        // descend into.
        let tabBar = node("AXGroup", label: "Tab Bar", x: 0, y: 873, w: 440, h: 83)
        let root = node("AXWindow", x: 0, y: 0, w: 440, h: 956, children: [tabBar])
        // The hit-test sweep found a button inside that container.
        let button = node("AXRadioButton", label: "Analytics", id: "analytics",
                          x: 215, y: 877, w: 104, h: 54)

        let merged = root.merging(discovered: [button])

        // The button is now reachable as a descendant of the Tab Bar
        // group — so a client-side hit-test selects the button, not
        // the group that used to shadow it.
        let hit = merged.hitTest(Point(x: 267, y: 904))
        #expect(hit?.label == "Analytics")
        #expect(hit?.role == "AXRadioButton")
    }

    @Test func `merging attaches to the root when no deeper container contains it`() {
        // Status bar lives above the app — no app container holds it.
        let root = node("AXWindow", x: 0, y: 60, w: 440, h: 896,
                        children: [node("AXStaticText", label: "Post", x: 0, y: 60, w: 100, h: 40)])
        let clock = node("AXStaticText", label: "4:37 PM", x: 40, y: 12, w: 60, h: 24)

        let merged = root.merging(discovered: [clock])
        #expect(merged.children.contains { $0.label == "4:37 PM" })
    }

    @Test func `merging de-duplicates discoveries against the tree and each other`() {
        let post = node("AXStaticText", label: "Post", id: "p1", x: 0, y: 60, w: 100, h: 40)
        let root = node("AXWindow", x: 0, y: 0, w: 440, h: 956, children: [post])
        let dupOfExisting = node("AXStaticText", label: "Post", id: "p1", x: 0, y: 60, w: 100, h: 40)
        let a = node("AXImage", label: "Wi-Fi", x: 380, y: 12, w: 24, h: 24)
        let b = node("AXImage", label: "Wi-Fi", x: 380, y: 12, w: 24, h: 24)

        let merged = root.merging(discovered: [dupOfExisting, a, b])
        // p1 already present (dropped); Wi-Fi added once.
        let wifiCount = countLabel(merged, "Wi-Fi")
        #expect(wifiCount == 1)
        #expect(countLabel(merged, "Post") == 1)
    }

    @Test func `merging returns self unchanged when nothing is new`() {
        let root = node("AXWindow", x: 0, y: 0, w: 440, h: 956,
                        children: [node("AXButton", id: "b", x: 0, y: 0, w: 10, h: 10)])
        #expect(root.merging(discovered: []) == root)
    }

    private func countLabel(_ n: AXNode, _ label: String) -> Int {
        (n.label == label ? 1 : 0) + n.children.reduce(0) { $0 + countLabel($1, label) }
    }
}
