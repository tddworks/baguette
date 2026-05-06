import Testing
import Foundation
import CoreGraphics
@testable import Baguette

/// Walk-tree-into-AXNode tests against `FakeAXTreeElement` —
/// `NSObject` subclasses that override KVC and the
/// `accessibilityFrame` selector. The walk is pure logic
/// (recursion, value extraction, frame projection, depth cap,
/// deadline short-circuit) so it lives in Domain and is fully
/// unit-tested here. The Infrastructure adapter feeds it the
/// real `AXPMacPlatformElement` returned by AXPTranslator's XPC
/// round-trip.
@Suite("AXNode.walk(from:transform:depthCap:deadline:)")
struct AXNodeWalkTests {

    // MARK: - leaf elements

    @Test func `leaf element produces a childless AXNode with role + label + frame`() {
        let leaf = FakeAXTreeElement(
            role: "AXButton",
            label: "Sign in",
            identifier: "sign-in",
            macFrame: CGRect(x: 100, y: 200, width: 80, height: 30)
        )
        let node = AXNode.walk(
            from: leaf,
            transform: AXFrameTransform(
                rootFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
                pointSize: CGSize(width: 1, height: 1)
            )
        )
        #expect(node.role == "AXButton")
        #expect(node.label == "Sign in")
        #expect(node.identifier == "sign-in")
        #expect(node.frame.origin == Point(x: 100, y: 200))
        #expect(node.frame.size == Size(width: 80, height: 30))
        #expect(node.children.isEmpty)
    }

    @Test func `missing role falls back to AXUnknown`() {
        let elem = FakeAXTreeElement()  // no role
        let node = AXNode.walk(from: elem, transform: identityTransform())
        #expect(node.role == "AXUnknown")
    }

    @Test func `walk reads enabled, focused, hidden bool flags via KVC`() {
        let elem = FakeAXTreeElement(
            role: "AXButton",
            booleans: [
                "accessibilityEnabled": false,
                "isAccessibilityFocused": true,
                "isAccessibilityHidden": true,
            ]
        )
        let node = AXNode.walk(from: elem, transform: identityTransform())
        #expect(node.enabled == false)
        #expect(node.focused == true)
        #expect(node.hidden == true)
    }

    @Test func `NSNumber accessibilityValue is stringified`() {
        let elem = FakeAXTreeElement(
            role: "AXSlider",
            numberValue: NSNumber(value: 0.42)
        )
        let node = AXNode.walk(from: elem, transform: identityTransform())
        #expect(node.value == "0.42")
    }

    // MARK: - recursion

    @Test func `walk recurses through accessibilityChildren depth-first`() {
        let leaf1 = FakeAXTreeElement(role: "AXStaticText", label: "first")
        let leaf2 = FakeAXTreeElement(role: "AXStaticText", label: "second")
        let parent = FakeAXTreeElement(
            role: "AXGroup",
            children: [leaf1, leaf2]
        )
        let root = FakeAXTreeElement(
            role: "AXApplication",
            children: [parent]
        )

        let node = AXNode.walk(from: root, transform: identityTransform())
        #expect(node.role == "AXApplication")
        #expect(node.children.count == 1)
        #expect(node.children[0].role == "AXGroup")
        #expect(node.children[0].children.count == 2)
        #expect(node.children[0].children.map(\.label) == ["first", "second"])
    }

    @Test func `depth cap stops recursion at the configured level`() {
        // Build: root → c1 → c2 → c3 (4 levels deep). The cap is
        // expressed as "the depth at which children are dropped" —
        // a child whose own depth equals the cap walks its
        // attributes but emits no grandchildren.
        let c3 = FakeAXTreeElement(role: "AXButton")
        let c2 = FakeAXTreeElement(role: "AXGroup", children: [c3])
        let c1 = FakeAXTreeElement(role: "AXGroup", children: [c2])
        let root = FakeAXTreeElement(role: "AXApplication", children: [c1])

        // depthCap: 1 → root (depth 0) + first-level children
        // (depth 1, where 1 >= 1 stops further recursion).
        let node = AXNode.walk(from: root, transform: identityTransform(), depthCap: 1)
        #expect(node.role == "AXApplication")
        #expect(node.children.count == 1)
        #expect(node.children[0].role == "AXGroup")  // c1
        #expect(node.children[0].children.isEmpty)   // c2 dropped at the cap
    }

    @Test func `deadline in the past short-circuits child traversal`() {
        let c1 = FakeAXTreeElement(role: "AXButton")
        let root = FakeAXTreeElement(role: "AXApplication", children: [c1])
        let node = AXNode.walk(
            from: root,
            transform: identityTransform(),
            deadline: Date(timeIntervalSinceNow: -1)  // already past
        )
        // Root is still emitted (we always read its own attributes
        // — the deadline gates *child traversal*).
        #expect(node.role == "AXApplication")
        #expect(node.children.isEmpty)
    }

    // MARK: - frame transform application

    @Test func `child frames are projected through the supplied AXFrameTransform`() {
        let leaf = FakeAXTreeElement(
            role: "AXButton",
            macFrame: CGRect(x: 200, y: 400, width: 100, height: 80)
        )
        let root = FakeAXTreeElement(
            role: "AXApplication",
            children: [leaf],
            macFrame: CGRect(x: 0, y: 0, width: 786, height: 1704)
        )
        // 2:1 scale → halves coordinates and dimensions.
        let transform = AXFrameTransform(
            rootFrame: CGRect(x: 0, y: 0, width: 786, height: 1704),
            pointSize: CGSize(width: 393, height: 852)
        )
        let node = AXNode.walk(from: root, transform: transform)
        #expect(node.children[0].frame.origin == Point(x: 100, y: 200))
        #expect(node.children[0].frame.size == Size(width: 50, height: 40))
    }

    // MARK: - resilience

    @Test func `accessibilityChildren absent yields no children, not an error`() {
        let elem = FakeAXTreeElement(role: "AXButton")  // no children key
        let node = AXNode.walk(from: elem, transform: identityTransform())
        #expect(node.children.isEmpty)
    }

    @Test func `non-array accessibilityChildren is treated as empty`() {
        let elem = FakeAXTreeElement(
            role: "AXButton",
            childrenAny: NSObject()  // not an [NSObject]
        )
        let node = AXNode.walk(from: elem, transform: identityTransform())
        #expect(node.children.isEmpty)
    }
}

// MARK: - Test fakes

private func identityTransform() -> AXFrameTransform {
    AXFrameTransform(
        rootFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
        pointSize: CGSize(width: 1, height: 1)
    )
}

/// `NSObject` subclass impersonating an `AXPMacPlatformElement`.
/// Returns whatever the test wired into it for the KVC keys the
/// walk reads, plus an `accessibilityFrame` selector that hands
/// back a stored CGRect (the walk reads frames via a typed IMP
/// cast, not KVC, because CGRect can't ride through KVC's
/// type-erased return).
final class FakeAXTreeElement: NSObject {
    let strings: [String: String]
    let booleans: [String: Bool]
    let numberValue: NSNumber?
    let children: [FakeAXTreeElement]
    let childrenAny: Any?
    let macFrame: CGRect

    init(
        role: String? = nil,
        subrole: String? = nil,
        label: String? = nil,
        value: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        help: String? = nil,
        booleans: [String: Bool] = [:],
        numberValue: NSNumber? = nil,
        children: [FakeAXTreeElement] = [],
        childrenAny: Any? = nil,
        macFrame: CGRect = CGRect(x: 0, y: 0, width: 0, height: 0)
    ) {
        var s: [String: String] = [:]
        if let role       { s["accessibilityRole"]       = role }
        if let subrole    { s["accessibilitySubrole"]    = subrole }
        if let label      { s["accessibilityLabel"]      = label }
        if let value      { s["accessibilityValue"]      = value }
        if let identifier { s["accessibilityIdentifier"] = identifier }
        if let title      { s["accessibilityTitle"]      = title }
        if let help       { s["accessibilityHelp"]       = help }
        self.strings = s
        self.booleans = booleans
        self.numberValue = numberValue
        self.children = children
        self.childrenAny = childrenAny
        self.macFrame = macFrame
        super.init()
    }

    override func value(forKey key: String) -> Any? {
        if let s = strings[key] { return s }
        if let b = booleans[key] { return NSNumber(value: b) }
        if key == "accessibilityValue", let n = numberValue { return n }
        if key == "accessibilityChildren" {
            if let custom = childrenAny { return custom }
            return children.isEmpty ? nil : children as [NSObject]
        }
        return nil
    }

    /// Match the typed IMP cast the walk uses to read CGRect-
    /// returning selectors. Declared `@objc dynamic` so the
    /// runtime exposes a callable IMP for `class_getMethodImplementation`.
    @objc dynamic func accessibilityFrame() -> CGRect {
        macFrame
    }
}
