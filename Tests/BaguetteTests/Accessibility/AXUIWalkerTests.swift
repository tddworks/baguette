import Testing
import Foundation
import CoreGraphics
@testable import Baguette

/// Walk-tree-into-AXNode tests for the macOS `AXUIElement` path.
/// The walker is generic over an opaque `Element` type so tests can
/// drive it with simple value-type fakes (no NSObject runtime); the
/// production adapter passes closures backed by
/// `AXUIElementCopyAttributeValue`.
@Suite("AXUIWalker.walk(from:reader:)")
struct AXUIWalkerTests {

    // MARK: - test fake

    /// Plain-struct stand-in for an `AXUIElement`. Carries every
    /// attribute the reader closures consume; the walker never sees
    /// `AXUIElement` itself, only an opaque `E`.
    private struct FakeElement: Equatable {
        var role: String?      = "AXButton"
        var subrole: String?   = nil
        var label: String?     = nil
        var value: String?     = nil
        var identifier: String? = nil
        var title: String?     = nil
        var help: String?      = nil
        var enabled: Bool      = true
        var focused: Bool      = false
        var hidden: Bool       = false
        var frame: CGRect      = .zero
        var children: [FakeElement] = []
    }

    /// Build a reader that pulls every attribute off the FakeElement
    /// directly. The production reader pulls them via
    /// `AXUIElementCopyAttributeValue`.
    private func reader() -> AXUIReader<FakeElement> {
        AXUIReader<FakeElement>(
            role:       { $0.role },
            subrole:    { $0.subrole },
            label:      { $0.label },
            value:      { $0.value },
            identifier: { $0.identifier },
            title:      { $0.title },
            help:       { $0.help },
            enabled:    { $0.enabled },
            focused:    { $0.focused },
            hidden:     { $0.hidden },
            frame:      { $0.frame },
            children:   { $0.children }
        )
    }

    // MARK: - leaf elements

    @Test func `leaf element produces a childless AXNode with role + label + frame`() {
        let leaf = FakeElement(
            role: "AXButton",
            label: "Sign in",
            identifier: "sign-in",
            frame: CGRect(x: 100, y: 200, width: 80, height: 30)
        )
        let node = AXUIWalker.walk(from: leaf, reader: reader())
        #expect(node.role == "AXButton")
        #expect(node.label == "Sign in")
        #expect(node.identifier == "sign-in")
        #expect(node.frame.origin == Point(x: 100, y: 200))
        #expect(node.frame.size == Size(width: 80, height: 30))
        #expect(node.children.isEmpty)
    }

    @Test func `missing role falls back to AXUnknown`() {
        let elem = FakeElement(role: nil)
        let node = AXUIWalker.walk(from: elem, reader: reader())
        #expect(node.role == "AXUnknown")
    }

    @Test func `walk reads enabled focused hidden flags`() {
        let elem = FakeElement(
            role: "AXButton",
            enabled: false,
            focused: true,
            hidden: true
        )
        let node = AXUIWalker.walk(from: elem, reader: reader())
        #expect(node.enabled == false)
        #expect(node.focused == true)
        #expect(node.hidden == true)
    }

    @Test func `optional string fields surface as nil when absent`() {
        let elem = FakeElement(role: "AXButton")
        let node = AXUIWalker.walk(from: elem, reader: reader())
        #expect(node.subrole == nil)
        #expect(node.label == nil)
        #expect(node.value == nil)
        #expect(node.title == nil)
        #expect(node.help == nil)
    }

    // MARK: - recursion

    @Test func `walk recurses through children depth-first`() {
        let leaf1 = FakeElement(role: "AXStaticText", label: "first")
        let leaf2 = FakeElement(role: "AXStaticText", label: "second")
        let parent = FakeElement(
            role: "AXGroup",
            children: [leaf1, leaf2]
        )
        let node = AXUIWalker.walk(from: parent, reader: reader())
        #expect(node.role == "AXGroup")
        #expect(node.children.count == 2)
        #expect(node.children[0].label == "first")
        #expect(node.children[1].label == "second")
    }

    @Test func `walk preserves nested-tree structure`() {
        let grandchild = FakeElement(role: "AXStaticText", label: "leaf")
        let child = FakeElement(role: "AXGroup", children: [grandchild])
        let root = FakeElement(role: "AXWindow", children: [child])
        let node = AXUIWalker.walk(from: root, reader: reader())
        #expect(node.role == "AXWindow")
        #expect(node.children[0].role == "AXGroup")
        #expect(node.children[0].children[0].role == "AXStaticText")
        #expect(node.children[0].children[0].label == "leaf")
    }

    // MARK: - safety bounds

    @Test func `walk halts recursion at depthCap`() {
        // Build a chain that's deeper than the cap so we know the
        // cap fires and not natural depth.
        var chain = FakeElement(role: "AXStaticText", label: "leaf")
        for _ in 0..<10 {
            chain = FakeElement(role: "AXGroup", children: [chain])
        }
        let node = AXUIWalker.walk(from: chain, reader: reader(), depthCap: 3)
        // depth-cap of 3 means root=0, child=1, grandchild=2 are
        // walked, but the great-grandchild's children are dropped.
        var depth = 0
        var cur = node
        while let next = cur.children.first {
            cur = next
            depth += 1
        }
        #expect(depth <= 3)
    }

    @Test func `walk halts recursion past deadline`() {
        // Deadline already in the past — root is walked but
        // children should be dropped.
        let parent = FakeElement(
            role: "AXGroup",
            children: [
                FakeElement(role: "AXStaticText", label: "first"),
            ]
        )
        let node = AXUIWalker.walk(
            from: parent,
            reader: reader(),
            deadline: Date(timeIntervalSinceNow: -1)
        )
        #expect(node.role == "AXGroup")
        #expect(node.children.isEmpty)
    }

    // MARK: - origin offset (window-relative coordinates)

    @Test func `originOffset subtracts from every nested frame`() {
        // Window origin at (50, 80). A child labelled at AX
        // screen-global (150, 180) should land at window-relative
        // (100, 100) after the offset is applied.
        let child = FakeElement(
            role: "AXButton",
            label: "ok",
            frame: CGRect(x: 150, y: 180, width: 40, height: 20)
        )
        let root = FakeElement(
            role: "AXWindow",
            frame: CGRect(x: 50, y: 80, width: 200, height: 400),
            children: [child]
        )
        let node = AXUIWalker.walk(
            from: root,
            reader: reader(),
            originOffset: CGPoint(x: 50, y: 80)
        )
        #expect(node.frame.origin == Point(x: 0, y: 0))
        #expect(node.children[0].frame.origin == Point(x: 100, y: 100))
        #expect(node.children[0].frame.size == Size(width: 40, height: 20))
    }

    @Test func `originOffset of zero leaves frames screen-global`() {
        let child = FakeElement(
            role: "AXButton",
            frame: CGRect(x: 100, y: 200, width: 40, height: 20)
        )
        let root = FakeElement(role: "AXWindow", children: [child])
        let node = AXUIWalker.walk(from: root, reader: reader())
        #expect(node.children[0].frame.origin == Point(x: 100, y: 200))
    }
}
