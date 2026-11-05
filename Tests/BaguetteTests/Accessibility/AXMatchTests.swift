import Testing
import Foundation
@testable import Baguette

/// A live element is found again from what was read a moment ago, and a control can
/// have moved a little since: a pulsing glow, the end of an animation.
@Suite("AXNode matching a live element")
struct AXMatchTests {
    private func button(_ label: String?, x: Double = 100, y: Double = 100) -> AXNode {
        AXNode(role: "AXButton", label: label, frame: Rect(origin: Point(x: x, y: y), size: Size(width: 40, height: 40)))
    }

    @Test func `should find an element that has moved a little`() {
        let moved = button("Select Photo", x: 103, y: 98)

        #expect(button("Select Photo").bestMatch(among: [moved]) == moved)
    }

    @Test func `should choose the nearest of several with the same name`() {
        let far = button(nil, x: 300)
        let near = button(nil, x: 104)

        #expect(button(nil).bestMatch(among: [far, near]) == near)
    }

    @Test func `should find a named element that has moved a long way, when it's the only one`() {
        let moved = button("Select Photo", y: 500)

        #expect(button("Select Photo").bestMatch(among: [moved]) == moved)
    }

    @Test func `should not take a nameless element that has moved a long way for the same one`() {
        #expect(button(nil).bestMatch(among: [button(nil, x: 300)]) == nil)
    }

    @Test func `should not match an element with another name or role`() {
        let other = AXNode(role: "AXStaticText", label: "Select Photo", frame: button("x").frame)

        #expect(button("Select Photo").bestMatch(among: [button("Cancel"), other]) == nil)
    }

    @Test func `should treat a small pulse as the same screen`() {
        let tree = AXNode(role: "AXApplication", label: "A", frame: button("x").frame, children: [button("Go")])
        let pulsed = AXNode(role: "AXApplication", label: "A", frame: button("x").frame, children: [button("Go", x: 102, y: 99)])

        #expect(tree.looksSame(as: pulsed))
    }

    @Test func `should count a scroll as a change`() {
        let tree = AXNode(role: "AXApplication", label: "A", frame: button("x").frame, children: [button("Go")])
        let scrolled = AXNode(role: "AXApplication", label: "A", frame: button("x").frame, children: [button("Go", y: 60)])

        #expect(!tree.looksSame(as: scrolled))
    }

    @Test func `should count a changed value, name or enabled state as a change`() {
        let on = AXNode(role: "AXSwitch", label: "Wi-Fi", value: "1", frame: button("x").frame)
        let off = AXNode(role: "AXSwitch", label: "Wi-Fi", value: "0", frame: button("x").frame)
        let disabled = AXNode(role: "AXSwitch", label: "Wi-Fi", value: "1", frame: button("x").frame, enabled: false)

        #expect(!on.looksSame(as: off))
        #expect(!on.looksSame(as: disabled))
        #expect(!button("A").looksSame(as: button("B")))
    }

    @Test func `should count a control appearing as a change`() {
        let empty = AXNode(role: "AXApplication", frame: button("x").frame)
        let filled = AXNode(role: "AXApplication", frame: button("x").frame, children: [button("Go")])

        #expect(!empty.looksSame(as: filled))
    }
}
