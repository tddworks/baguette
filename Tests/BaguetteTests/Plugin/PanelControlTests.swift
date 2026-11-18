import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// Tickable rows — switches, checkboxes and radios.
///
/// The behaviour this replaces is `display.py` writing `"● Light"` /
/// `"○ Dark"` into row *titles*: a plugin drawing a control glyph inside
/// a string, in a page whose premise is that the host owns every pixel.
/// It was safe (everything is escaped) but not right — the host couldn't
/// style it, a screen reader read a bullet, and "which one is on" was
/// legible only to a human eye.
///
/// So the row says what's *on* and the manifest says what *on looks
/// like*. Ticking is local and batched: the panel accumulates ticks and
/// submits them together, which buys one subprocess per batch instead of
/// one per tick, at the cost of rows briefly showing unconfirmed state.
@Suite("PanelControl")
struct PanelControlTests {

    private func body(_ json: String, commands: Set<String> = ["flags"]) throws -> ListBody {
        try ListBody.parsing(
            dict: JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:],
            declaredCommands: commands
        )
    }

    private func row(_ json: String) throws -> ResultRow {
        try ResultRow.parsing(
            dict: JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:],
            index: 0
        )
    }

    // MARK: - the manifest side

    @Test func `should let a panel declare tickable rows`() throws {
        let parsed = try body("""
        {"kind":"list","source":"flags",
         "control":{"kind":"checkbox","arg":"enabled","submit":"Apply"}}
        """)
        #expect(parsed.control == PanelControl(kind: .checkbox, arg: "enabled", submit: "Apply"))
    }

    @Test func `should offer switch, checkbox and radio controls`() throws {
        for kind in ["switch", "checkbox", "radio"] {
            let parsed = try body(#"{"kind":"list","source":"flags","control":{"kind":"\#(kind)","arg":"e"}}"#)
            #expect(parsed.control?.kind.rawValue == kind)
        }
    }

    @Test func `should label the submit button Apply when the control names no label`() throws {
        #expect(try body(#"{"kind":"list","source":"flags","control":{"kind":"switch","arg":"e"}}"#)
            .control?.submit == "Apply")
    }

    @Test func `should reject an unknown control family rather than draw the nearest one`() throws {
        // Unlike an icon, this doesn't degrade. A checkbox silently drawn
        // as a switch would misrepresent whether ticking two at once is
        // allowed — a lie about behaviour, not a substituted picture.
        #expect(throws: PluginManifestError.unknownRowControl(name: "dial")) {
            _ = try body(#"{"kind":"list","source":"flags","control":{"kind":"dial","arg":"e"}}"#)
        }
    }

    @Test func `should reject a control when it names no arg to submit ticks under`() throws {
        #expect(throws: PluginManifestError.missingControlArg) {
            _ = try body(#"{"kind":"list","source":"flags","control":{"kind":"switch"}}"#)
        }
        #expect(throws: PluginManifestError.missingControlArg) {
            _ = try body(#"{"kind":"list","source":"flags","control":{"kind":"switch","arg":""}}"#)
        }
    }

    @Test func `should draw a plain list when the panel declares no control`() throws {
        #expect(try body(#"{"kind":"list","source":"flags"}"#).control == nil)
    }

    // MARK: - the row side

    @Test func `should report whether a row is on or off`() throws {
        #expect(try row(#"{"title":"Dark Mode","value":"dark","state":"on"}"#).state == .on)
        #expect(try row(#"{"title":"Bold Text","value":"bold","state":"off"}"#).state == .off)
    }

    @Test func `should carry the value a row's tick submits`() throws {
        #expect(try row(#"{"title":"Camera","value":"camera","state":"on"}"#).value == "camera")
    }

    @Test func `should name the group a row's radio is exclusive within`() throws {
        // A settings panel is several independent questions at once —
        // display.py has appearance, contrast and text size. Without
        // groups a radio panel could only ever ask one, because picking
        // "Dark" would unpick the text size.
        let row = try row(#"{"title":"Dark","value":"appearance:dark","state":"off","group":"appearance"}"#)
        #expect(row.group == "appearance")
    }

    @Test func `should leave a row ungrouped when it names no group, as in a single-question panel`() throws {
        #expect(try row(#"{"title":"Camera","value":"camera","state":"on"}"#).group == nil)
    }

    @Test func `should treat a row as a plain header when it has no state`() throws {
        // `display.py` opens each group with a title-only row. Those must
        // keep rendering as plain rows inside a control panel, not turn
        // into unticked checkboxes.
        let plain = try row(#"{"title":"Appearance"}"#)
        #expect(plain.state == nil)
        #expect(plain.value == nil)
    }

    @Test func `should reject an unknown row state rather than read it as off`() throws {
        // Defaulting to "off" would render a switch that says the feature
        // is disabled when the plugin never claimed that.
        #expect(throws: PluginResultError.unknownRowState(name: "maybe", index: 0)) {
            _ = try row(#"{"title":"X","value":"x","state":"maybe"}"#)
        }
    }

    @Test func `should reject a row state when it has no value to submit`() throws {
        #expect(throws: PluginResultError.stateWithoutValue(index: 0)) {
            _ = try row(#"{"title":"Dark Mode","state":"on"}"#)
        }
    }

    // MARK: - what the browser receives

    @Test func `should tell the browser how to draw the control and what to submit`() throws {
        let manifest = try PluginManifest.parsing(json: Data("""
        {"name":"flags","version":"1.0.0",
         "contributes":{
           "commands":[{"id":"flags","title":"Flags","run":["node","x.js"]}],
           "panels":[{"id":"flags","title":"Flags","icon":"wrench",
             "body":{"kind":"list","source":"flags",
                     "control":{"kind":"radio","arg":"appearance","submit":"Set"}}}]}}
        """.utf8))
        let plugins = MockPlugins()
        given(plugins).all().willReturn([
            Plugin(root: URL(fileURLWithPath: "/tmp/flags"), manifest: manifest)
        ])

        let root = try #require(
            JSONSerialization.jsonObject(with: Data(try plugins.listJSON.utf8)) as? [String: Any]
        )
        let panels = ((root["plugins"] as? [[String: Any]])?.first?["panels"] as? [[String: Any]]) ?? []
        let control = (panels.first?["body"] as? [String: Any])?["control"] as? [String: Any]

        #expect(control?["kind"] as? String == "radio")
        #expect(control?["arg"] as? String == "appearance")
        #expect(control?["submit"] as? String == "Set")
    }

    @Test func `should pass a row's state, value and group to the browser`() throws {
        let dict = try row("""
        {"title":"Dark","value":"appearance:dark","state":"on","group":"appearance"}
        """).dictionary
        #expect(dict["state"] as? String == "on")
        #expect(dict["value"] as? String == "appearance:dark")
        #expect(dict["group"] as? String == "appearance")
    }

    @Test func `should send no state or value for a plain row so old panels stay byte-identical`() throws {
        let dict = try row(#"{"title":"Button has no label"}"#).dictionary
        #expect(dict["state"] == nil)
        #expect(dict["value"] == nil)
    }
}
