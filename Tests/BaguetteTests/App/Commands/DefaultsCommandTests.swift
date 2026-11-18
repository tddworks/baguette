import Testing
import Foundation
import ArgumentParser
@testable import Baguette
@testable import BaguetteDevice

/// `baguette defaults read|write|delete` — the flags map onto Domain
/// values (`PreferenceSuite`, `PreferenceEdit`) the run path hands to
/// `Defaults`, so the mapping is the thing worth pinning.
@Suite("DefaultsCommand")
struct DefaultsCommandTests {

    @Test func `should offer read, write and delete under defaults`() {
        #expect(DefaultsCommand.configuration.commandName == "defaults")
        #expect(DefaultsCommand.configuration.subcommands.map { $0.configuration.commandName }
            == ["read", "write", "delete", "export", "import"])
    }

    @Test func `should read the app's standard defaults when no suite is given`() throws {
        let cmd = try DefaultsCommand.Read.parse(["--udid", "U", "--bundle-id", "com.x"])
        #expect(try cmd.target.preferenceSuite() == PreferenceSuite(bundleID: "com.x"))
        #expect(cmd.key == nil)
    }

    @Test func `should read an App Group suite when one is given`() throws {
        let cmd = try DefaultsCommand.Read.parse([
            "--udid", "U", "--bundle-id", "com.x", "--suite", "group.x", "--key", "k", "--json",
        ])
        #expect(try cmd.target.preferenceSuite() == PreferenceSuite(bundleID: "com.x", name: "group.x"))
        #expect(cmd.key == "k")
        #expect(cmd.json)
    }

    @Test func `should write a value as the type given on the command line`() throws {
        let cmd = try DefaultsCommand.Write.parse([
            "--udid", "U", "--bundle-id", "com.x", "--key", "seen", "--type", "bool", "--value", "false",
        ])
        #expect(try cmd.edit() == PreferenceEdit(
            suite: PreferenceSuite(bundleID: "com.x"), key: "seen", change: .set(.bool(false))
        ))
    }

    @Test func `should quit and relaunch the app around a write when asked to`() throws {
        let cmd = try DefaultsCommand.Write.parse([
            "--udid", "U", "--bundle-id", "com.x", "--key", "n", "--type", "int", "--value", "3",
            "--relaunch",
        ])
        #expect(try cmd.edit().relaunch == .always)
    }

    @Test func `should relaunch around a write only when the running app needs it when asked to`() throws {
        let cmd = try DefaultsCommand.Write.parse([
            "--udid", "U", "--bundle-id", "com.x", "--key", "n", "--type", "int", "--value", "3",
            "--relaunch-if-needed",
        ])
        #expect(try cmd.edit().relaunch == .whenNeeded)
    }

    @Test func `should refuse to relaunch both always and only when needed`() {
        #expect(throws: (any Error).self) {
            try DefaultsCommand.Delete.parse([
                "--udid", "U", "--bundle-id", "com.x", "--key", "n", "--relaunch", "--relaunch-if-needed",
            ])
        }
    }

    @Test func `should refuse a write whose value is not of its type`() throws {
        let cmd = try DefaultsCommand.Write.parse([
            "--udid", "U", "--bundle-id", "com.x", "--key", "n", "--type", "int", "--value", "x",
        ])
        #expect(throws: PreferenceValueError.notA(.int, "x")) { try cmd.edit() }
    }

    @Test func `should refuse a write with an unknown type`() {
        #expect(throws: (any Error).self) {
            try DefaultsCommand.Write.parse([
                "--udid", "U", "--bundle-id", "com.x", "--key", "n", "--type", "double", "--value", "1",
            ])
        }
    }

    @Test func `should remove a key from a suite`() throws {
        let cmd = try DefaultsCommand.Delete.parse([
            "--udid", "U", "--bundle-id", "com.x", "--suite", "group.x", "--key", "seen",
        ])
        #expect(try cmd.edit() == PreferenceEdit(
            suite: PreferenceSuite(bundleID: "com.x", name: "group.x"), key: "seen", change: .remove
        ))
    }

    @Test func `should refuse a defaults command without a bundle id`() {
        #expect(throws: (any Error).self) {
            try DefaultsCommand.Read.parse(["--udid", "U"])
        }
    }

    @Test func `should print each stored preference with its type, in key order`() {
        let preferences = Preferences(values: [
            "seen": .bool(false), "name": .string("Ada"), "tags": .array([.integer(1)]),
        ])
        #expect(DefaultsCommand.Read.text(preferences, key: nil) == """
        name = Ada (string)
        seen = false (bool)
        tags = <array><integer>1</integer></array> (array)
        """)
    }

    @Test func `should print the settings the running app looks up but nothing stores after the stored ones`() {
        let preferences = Preferences(values: ["desk": .string("rows")])
        let unset = [
            PreferenceLookup(key: "shelf.preview", type: .bool),
            PreferenceLookup(key: "token", type: nil),
            PreferenceLookup(key: "volume", type: .float, registered: .real(0.5)),
        ]
        #expect(DefaultsCommand.Read.text(preferences, key: nil, unset: unset) == """
        desk = rows (string)
        shelf.preview is not set (bool, the app's own default)
        token is not set (the app's own default)
        volume is not set (float, registered 0.5)
        """)
    }

    @Test func `should say a key is not set rather than print a value for it`() {
        #expect(DefaultsCommand.Read.text(Preferences(values: [:]), key: "seen") == "seen is not set")
        #expect(DefaultsCommand.Read.text(Preferences(values: ["seen": .integer(0)]), key: "seen")
            == "seen = 0 (int)")
    }

    @Test func `should export every stored preference when no keys are named`() throws {
        let cmd = try DefaultsCommand.Export.parse(["--udid", "U", "--bundle-id", "com.x"])
        let json = cmd.export(Preferences(values: ["a": .integer(1), "b": .bool(true)]), from: try cmd.target.preferenceSuite())
        #expect(json as NSDictionary == [
            "bundleId": "com.x",
            "values": ["a": ["type": "int", "value": 1], "b": ["type": "bool", "value": true]],
        ] as NSDictionary)
    }

    @Test func `should export only the keys named`() throws {
        let cmd = try DefaultsCommand.Export.parse([
            "--udid", "U", "--bundle-id", "com.x", "--suite", "group.x", "--key", "b", "--key", "c",
        ])
        let json = cmd.export(Preferences(values: ["a": .integer(1), "b": .bool(true)]), from: try cmd.target.preferenceSuite())
        #expect(json as NSDictionary == [
            "bundleId": "com.x", "suite": "group.x",
            "values": ["b": ["type": "bool", "value": true]],
        ] as NSDictionary)
    }

    @Test func `should import an export into the suite named on the command line`() throws {
        let cmd = try DefaultsCommand.Import.parse([
            "--udid", "U", "--bundle-id", "com.y", "--file", "prefs.json", "--relaunch",
        ])
        let restore = try cmd.preferenceImport(
            from: Data(#"{"bundleId":"com.x","values":{"seen":{"type":"bool","value":false}}}"#.utf8)
        )
        #expect(restore == PreferenceImport(
            suite: try PreferenceSuite(bundleID: "com.y"),
            preferences: Preferences(values: ["seen": .bool(false)]),
            relaunch: .always
        ))
    }
}
