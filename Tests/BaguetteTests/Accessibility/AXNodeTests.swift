import Testing
import Foundation
@testable import Baguette

@Suite("AXNode")
struct AXNodeTests {

    // MARK: - identity & defaults

    @Test func `holds role, label, value, identifier, frame, traits`() {
        let node = AXNode(
            role: "AXButton",
            subrole: "AXSecureTextField",
            label: "Sign in",
            value: "user@example.com",
            identifier: "sign-in-button",
            title: "Login",
            help: "Tap to authenticate",
            frame: Rect(origin: Point(x: 12, y: 34),
                        size: Size(width: 100, height: 44)),
            enabled: true,
            focused: false,
            hidden: false,
            children: []
        )
        #expect(node.role == "AXButton")
        #expect(node.subrole == "AXSecureTextField")
        #expect(node.label == "Sign in")
        #expect(node.value == "user@example.com")
        #expect(node.identifier == "sign-in-button")
        #expect(node.title == "Login")
        #expect(node.help == "Tap to authenticate")
        #expect(node.frame.origin == Point(x: 12, y: 34))
        #expect(node.frame.size == Size(width: 100, height: 44))
        #expect(node.enabled)
        #expect(!node.focused)
        #expect(!node.hidden)
        #expect(node.children.isEmpty)
    }

    @Test func `optional string fields default to nil and children to empty`() {
        let node = AXNode(
            role: "AXGroup",
            frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 0, height: 0))
        )
        #expect(node.subrole == nil)
        #expect(node.label == nil)
        #expect(node.value == nil)
        #expect(node.identifier == nil)
        #expect(node.title == nil)
        #expect(node.help == nil)
        #expect(node.enabled)
        #expect(!node.focused)
        #expect(!node.hidden)
        #expect(node.children.isEmpty)
    }

    // MARK: - JSON projection

    @Test func `json round-trips required fields`() throws {
        let node = AXNode(
            role: "AXButton",
            label: "OK",
            identifier: "ok",
            frame: Rect(origin: Point(x: 10, y: 20), size: Size(width: 80, height: 30))
        )
        let dict = try parseJSON(node.json)

        #expect(dict["role"] as? String == "AXButton")
        #expect(dict["label"] as? String == "OK")
        #expect(dict["identifier"] as? String == "ok")
        let frame = dict["frame"] as? [String: Any]
        #expect(frame?["x"] as? Double == 10)
        #expect(frame?["y"] as? Double == 20)
        #expect(frame?["width"] as? Double == 80)
        #expect(frame?["height"] as? Double == 30)
        #expect(dict["enabled"] as? Bool == true)
        #expect(dict["focused"] as? Bool == false)
        #expect(dict["hidden"] as? Bool == false)
        #expect((dict["children"] as? [Any])?.isEmpty == true)
    }

    @Test func `json omits absent optional strings as null`() throws {
        let node = AXNode(
            role: "AXGroup",
            frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 0, height: 0))
        )
        let dict = try parseJSON(node.json)
        #expect(dict["subrole"] is NSNull)
        #expect(dict["label"] is NSNull)
        #expect(dict["value"] is NSNull)
        #expect(dict["identifier"] is NSNull)
        #expect(dict["title"] is NSNull)
        #expect(dict["help"] is NSNull)
    }

    @Test func `json nests children recursively`() throws {
        let leaf = AXNode(
            role: "AXStaticText",
            label: "Hello",
            frame: Rect(origin: Point(x: 1, y: 2), size: Size(width: 50, height: 20))
        )
        let parent = AXNode(
            role: "AXWindow",
            frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 390, height: 844)),
            children: [leaf]
        )
        let dict = try parseJSON(parent.json)
        let kids = dict["children"] as? [[String: Any]]
        #expect(kids?.count == 1)
        #expect(kids?.first?["role"] as? String == "AXStaticText")
        #expect(kids?.first?["label"] as? String == "Hello")
    }

    // MARK: - traversal

    @Test func `hitTest returns the deepest node containing the point`() {
        let leaf = AXNode(
            role: "AXButton", label: "OK",
            frame: Rect(origin: Point(x: 100, y: 200), size: Size(width: 80, height: 40))
        )
        let parent = AXNode(
            role: "AXWindow",
            frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 390, height: 844)),
            children: [leaf]
        )

        // Inside leaf → leaf wins.
        #expect(parent.hitTest(Point(x: 140, y: 220))?.role == "AXButton")
        // Outside leaf but inside parent → parent.
        #expect(parent.hitTest(Point(x: 10, y: 10))?.role == "AXWindow")
        // Outside parent → nil.
        #expect(parent.hitTest(Point(x: 1000, y: 1000)) == nil)
    }
}

private func parseJSON(_ s: String) throws -> [String: Any] {
    let data = Data(s.utf8)
    let obj = try JSONSerialization.jsonObject(with: data, options: [])
    return obj as? [String: Any] ?? [:]
}
