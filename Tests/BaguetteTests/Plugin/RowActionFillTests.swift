import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// `rowAction: "fill"` — a row that puts its text into the panel's own
/// prompt instead of doing something with it.
///
/// The other four actions all *act*: box a frame, tap it, copy it, run a
/// command. This one hands the row to the field above it, which is what
/// a list of suggestions under a text box has always meant. The
/// deep-link panel is the case that named it: clicking `account://` was
/// opening a bare scheme with no path, when what anyone wants is that
/// scheme in the box with the caret after it, ready for the rest of the
/// URL.
///
/// So the list stops being a launcher and becomes what it looks like —
/// completion.
@Suite("Row action fill")
struct RowActionFillTests {

    private func row(_ json: String) throws -> ResultRow {
        try ResultRow.parsing(
            dict: JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:],
            index: 0
        )
    }

    @Test func `should let a panel declare the fill row action`() throws {
        let body = try PanelBody.parsing(
            dict: ["kind": "list", "source": "open", "rowAction": "fill"],
            declaredCommands: ["open"]
        )
        #expect(body == .list(ListBody(source: "open", rowAction: .fill)))
    }

    @Test func `should carry the text a row fills the field with`() throws {
        #expect(try row(#"{"title":"account://","fill":"account://"}"#).fill == "account://")
    }

    @Test func `should keep what a row fills with separate from what it displays`() throws {
        // The title is display text — it may be truncated, decorated or
        // translated. Reusing it as the value would make every one of
        // those a silent change to what gets typed into the box.
        let row = try row(#"{"title":"Account (SpringBoard)","fill":"account://"}"#)
        #expect(row.title == "Account (SpringBoard)")
        #expect(row.fill == "account://")
    }

    @Test func `should fill nothing when a row names no fill text`() throws {
        #expect(try row(#"{"title":"Nothing here"}"#).fill == nil)
    }

    @Test func `should pass a row's fill text to the browser and omit it when unused`() throws {
        #expect(try row(#"{"title":"a","fill":"account://"}"#).dictionary["fill"] as? String
                == "account://")
        #expect(try row(#"{"title":"a"}"#).dictionary["fill"] == nil)
    }

    @Test func `should offer fill among the row actions a manifest may name`() {
        // The set is closed and the error message lists it, so a new
        // member has to show up there or authors can't discover it.
        #expect(RowAction.allCases.contains(.fill))
        #expect(
            PluginManifestError.unknownRowAction(name: "x").description.contains("fill")
        )
    }
}
