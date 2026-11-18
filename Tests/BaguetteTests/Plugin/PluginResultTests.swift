import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

@Suite("PluginResult")
struct PluginResultTests {

    // MARK: - the happy answer

    @Test func `should read whether the plugin answered ok`() throws {
        let result = try PluginResult.parsing(json: Self.fixtureRows)
        #expect(result.ok)
    }

    @Test func `should read a result row's title and subtitle`() throws {
        let result = try PluginResult.parsing(json: Self.fixtureRows)
        let row = try #require(result.rows.first)
        #expect(row.title == "Button has no label")
        #expect(row.subtitle == "AXButton")
    }

    @Test func `should read a result row's severity`() throws {
        let result = try PluginResult.parsing(json: Self.fixtureRows)
        #expect(result.rows.first?.severity == .error)
    }

    @Test func `should default a row's severity to info when the plugin omits it`() throws {
        let result = try PluginResult.parsing(json: Self.fixtureRows)
        #expect(result.rows.last?.severity == .info)
    }

    @Test func `should read a row's frame from flat device points`() throws {
        // Rows carry the same device-point space as gesture wire
        // coordinates, so `rowAction: highlight` can hand the frame
        // straight to the AX inspector with no conversion.
        let result = try PluginResult.parsing(json: Self.fixtureRows)
        #expect(result.rows.first?.frame == Rect(
            origin: Point(x: 24, y: 380),
            size: Size(width: 44, height: 44)
        ))
    }

    @Test func `should leave a row's frame unset when the plugin omits it`() throws {
        let result = try PluginResult.parsing(json: Self.fixtureRows)
        #expect(result.rows.last?.frame == nil)
    }

    @Test func `should show no rows when the plugin answers with none`() throws {
        let result = try PluginResult.parsing(json: Self.fixtureBareOK)
        #expect(result.rows.isEmpty)
    }

    // MARK: - the plugin reporting its own failure

    @Test func `should let a plugin answer that it failed, with a message`() throws {
        // Distinct from baguette failing to run the plugin: the
        // process exited 0 and answered honestly. The host toasts the
        // message rather than inventing one.
        let result = try PluginResult.parsing(json: Self.fixtureNotOK)
        #expect(!result.ok)
        #expect(result.message == "Metro is not running on :8081")
    }

    // MARK: - answers baguette refuses to render

    @Test func `should reject plugin output when it is not JSON`() throws {
        // A plugin that logs to stdout instead of answering must fail
        // loudly — silently rendering nothing looks like "no problems
        // found", which is the worst possible lie for an audit panel.
        #expect(throws: PluginResultError.malformedJSON) {
            try PluginResult.parsing(json: Data("Debugger attached.".utf8))
        }
    }

    @Test func `should reject a result row when it has no title`() throws {
        #expect(throws: PluginResultError.rowMissingTitle(index: 1)) {
            try PluginResult.parsing(json: Self.fixtureRowNoTitle)
        }
    }

    @Test func `should reject a severity baguette has no style for`() throws {
        #expect(throws: PluginResultError.unknownSeverity(name: "catastrophe", index: 0)) {
            try PluginResult.parsing(json: Self.fixtureBadSeverity)
        }
    }

    @Test func `should reject a result row when its frame is partial`() throws {
        // Half a frame can't be highlighted or tapped. Better to
        // reject than to paint a box at a coordinate we guessed.
        #expect(throws: PluginResultError.malformedFrame(index: 0)) {
            try PluginResult.parsing(json: Self.fixturePartialFrame)
        }
    }

    // MARK: - fixtures

    static let fixtureRows = Data("""
    {"ok": true, "rows": [
      {"title": "Button has no label", "subtitle": "AXButton", "severity": "error",
       "frame": {"x": 24, "y": 380, "width": 44, "height": 44}},
      {"title": "Tap target is 32x32"}
    ]}
    """.utf8)

    static let fixtureBareOK = Data(#"{"ok": true}"#.utf8)

    static let fixtureNotOK = Data("""
    {"ok": false, "message": "Metro is not running on :8081"}
    """.utf8)

    static let fixtureRowNoTitle = Data("""
    {"ok": true, "rows": [{"title": "fine"}, {"subtitle": "orphan"}]}
    """.utf8)

    static let fixtureBadSeverity = Data("""
    {"ok": true, "rows": [{"title": "x", "severity": "catastrophe"}]}
    """.utf8)

    static let fixturePartialFrame = Data("""
    {"ok": true, "rows": [{"title": "x", "frame": {"x": 10, "y": 20}}]}
    """.utf8)
}
