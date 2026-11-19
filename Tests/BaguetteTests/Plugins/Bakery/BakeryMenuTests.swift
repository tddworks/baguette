import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

@Suite("BakeryMenu")
struct BakeryMenuTests {

    // MARK: - the menu

    @Test func `should read a menu's optional name and description`() throws {
        let menu = try BakeryMenu.parsing(json: Self.fixtureTwo)
        #expect(menu.name == "tddworks/baguette-plugins")
        #expect(menu.description == "Official baguette plugins")
    }

    @Test func `should leave a menu's name and description unset when omitted`() throws {
        let menu = try BakeryMenu.parsing(json: Self.fixtureBare)
        #expect(menu.name == nil)
        #expect(menu.description == nil)
    }

    @Test func `should read each plugin's name and path from the menu`() throws {
        let menu = try BakeryMenu.parsing(json: Self.fixtureTwo)
        #expect(menu.entries == [
            BakeryMenu.Entry(name: "a11y", path: "plugins/a11y"),
            BakeryMenu.Entry(name: "expo", path: "tools/expo"),
        ])
    }

    @Test func `should find a menu entry by name and none for a name it doesn't list`() throws {
        let menu = try BakeryMenu.parsing(json: Self.fixtureTwo)
        #expect(menu.entry(named: "expo")?.path == "tools/expo")
        #expect(menu.entry(named: "ghost") == nil)
    }

    // MARK: - rejections

    @Test func `should reject a menu that isn't JSON`() throws {
        #expect(throws: BakeryMenuError.malformedJSON) {
            try BakeryMenu.parsing(json: Data("not json".utf8))
        }
    }

    @Test func `should reject a menu with no plugins`() throws {
        // A repo without a plugins list isn't a bakery — better to say
        // so than to add a source that offers nothing.
        #expect(throws: BakeryMenuError.noPlugins) {
            try BakeryMenu.parsing(json: Data(#"{"name":"empty"}"#.utf8))
        }
    }

    @Test func `should reject a menu entry missing its path`() throws {
        #expect(throws: BakeryMenuError.entryMissingField(index: 0, field: "path")) {
            try BakeryMenu.parsing(json: Data(#"{"plugins":[{"name":"a"}]}"#.utf8))
        }
    }

    @Test func `should reject a menu entry missing its name`() throws {
        #expect(throws: BakeryMenuError.entryMissingField(index: 0, field: "name")) {
            try BakeryMenu.parsing(json: Data(#"{"plugins":[{"path":"x"}]}"#.utf8))
        }
    }

    @Test func `should refuse a plugin path that escapes the repo with dot-dot`() throws {
        // The path is joined onto the clone dir and copied out. `..`
        // would let a bakery reach into ~/.ssh or anywhere else on
        // disk — refuse it at the parse boundary.
        #expect(throws: BakeryMenuError.unsafePath(index: 0, path: "../../etc")) {
            try BakeryMenu.parsing(json: Data(#"{"plugins":[{"name":"evil","path":"../../etc"}]}"#.utf8))
        }
    }

    @Test func `should refuse an absolute plugin path`() throws {
        #expect(throws: BakeryMenuError.unsafePath(index: 0, path: "/etc/passwd")) {
            try BakeryMenu.parsing(json: Data(#"{"plugins":[{"name":"evil","path":"/etc/passwd"}]}"#.utf8))
        }
    }

    // MARK: - fixtures

    static let fixtureTwo = Data("""
    {
      "name": "tddworks/baguette-plugins",
      "description": "Official baguette plugins",
      "plugins": [
        { "name": "a11y", "path": "plugins/a11y" },
        { "name": "expo", "path": "tools/expo" }
      ]
    }
    """.utf8)

    static let fixtureBare = Data("""
    { "plugins": [ { "name": "solo", "path": "." } ] }
    """.utf8)
}
